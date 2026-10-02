import Foundation
import Testing
@testable import TimecardCore

/// 受け取ったリクエストを記録し、用意した応答を順に返す
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: String
    }

    var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(_ stubs: [Stub]) {
        self.stubs = stubs
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let stub = stubs.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        return (Data(stub.body.utf8), response)
    }

    func bodyString(_ index: Int) -> String {
        String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
    }

    func bodyJSON(_ index: Int) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())
        return object as? [String: Any] ?? [:]
    }
}

final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    var credentials: Credentials?

    init(_ credentials: Credentials?) {
        self.credentials = credentials
    }

    func load() throws -> Credentials? { credentials }
    func save(_ credentials: Credentials) throws { self.credentials = credentials }
    func clear() throws { credentials = nil }
}

@Suite struct FreeeClientTests {
    let now = jst("2026-10-02 08:50")
    let tokenJSON = #"{"access_token":"new-access","token_type":"bearer","expires_in":21600,"refresh_token":"new-refresh","scope":"read write","created_at":1790898600}"#

    func credentials(expiresAt: Date) -> Credentials {
        Credentials(
            clientID: "cid",
            clientSecret: "secret",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: expiresAt,
            companyID: 10,
            employeeID: 20
        )
    }

    func makeClient(_ transport: FakeTransport, _ store: MemoryCredentialStore) -> FreeeClient {
        let now = now
        return FreeeClient(store: store, transport: transport, now: { now })
    }

    @Test func 打刻一覧を取得して日時を解釈する() async throws {
        let transport = FakeTransport([
            .init(status: 200, body: #"[{"id":1,"date":"2026-10-01","type":"clock_in","datetime":"2026-10-01T09:00:00.000+09:00","original_datetime":"2026-10-01T09:00:00.000+09:00","note":""}]"#)
        ])
        let client = makeClient(transport, MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(3600))))

        let clocks = try await client.timeClocks(from: "2026-09-30", to: "2026-10-02")

        #expect(clocks == [TimeClock(date: "2026-10-01", type: .clockIn, datetime: jst("2026-10-01 09:00"))])
        let request = transport.requests[0]
        #expect(request.url?.absoluteString == "https://api.freee.co.jp/hr/api/v1/employees/20/time_clocks?company_id=10&from_date=2026-09-30&to_date=2026-10-02&limit=100")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access")
    }

    @Test func 出勤を打刻する() async throws {
        let transport = FakeTransport([
            .init(status: 201, body: #"{"employee_time_clock":{"id":2,"date":"2026-10-02","type":"clock_in","datetime":"2026-10-02T08:50:00.000+09:00"}}"#)
        ])
        let client = makeClient(transport, MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(3600))))

        let clock = try await client.postTimeClock(type: .clockIn, baseDate: nil)

        #expect(clock == TimeClock(date: "2026-10-02", type: .clockIn, datetime: jst("2026-10-02 08:50")))
        #expect(transport.requests[0].httpMethod == "POST")
        #expect(transport.requests[0].url?.absoluteString == "https://api.freee.co.jp/hr/api/v1/employees/20/time_clocks")
        let body = transport.bodyJSON(0)
        #expect(body["company_id"] as? Int == 10)
        #expect(body["type"] as? String == "clock_in")
        #expect(body["base_date"] == nil)
    }

    @Test func 退勤打刻に打刻日を付ける() async throws {
        let transport = FakeTransport([
            .init(status: 201, body: #"{"employee_time_clock":{"id":3,"date":"2026-10-01","type":"clock_out","datetime":"2026-10-02T08:50:00.000+09:00"}}"#)
        ])
        let client = makeClient(transport, MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(3600))))

        _ = try await client.postTimeClock(type: .clockOut, baseDate: "2026-10-01")

        #expect(transport.bodyJSON(0)["base_date"] as? String == "2026-10-01")
    }

    @Test func 勤怠を取得する() async throws {
        let transport = FakeTransport([
            .init(status: 200, body: #"{"date":"2026-10-01","clock_in_at":"2026-10-01T09:00:00.000+09:00","clock_out_at":null,"break_records":[{"clock_in_at":"2026-10-01T12:00:00.000+09:00","clock_out_at":"2026-10-01T13:00:00.000+09:00"}],"note":"在宅","is_editable":true}"#)
        ])
        let client = makeClient(transport, MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(3600))))

        let record = try await client.workRecord(date: "2026-10-01")

        #expect(record == WorkRecord(
            date: "2026-10-01",
            clockInAt: jst("2026-10-01 09:00"),
            clockOutAt: nil,
            breakRecords: [TimeRange(start: jst("2026-10-01 12:00"), end: jst("2026-10-01 13:00"))],
            note: "在宅"
        ))
        #expect(transport.requests[0].url?.absoluteString == "https://api.freee.co.jp/hr/api/v1/employees/20/work_records/2026-10-01?company_id=10")
    }

    @Test func 勤怠の更新は日本時間の文字列で送る() async throws {
        let transport = FakeTransport([.init(status: 200, body: "{}")])
        let client = makeClient(transport, MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(3600))))
        let update = WorkRecordUpdate(
            segments: [TimeRange(start: jst("2026-10-01 18:00"), end: jst("2026-10-02 03:00"))],
            breakRecords: [TimeRange(start: jst("2026-10-01 20:00"), end: jst("2026-10-01 21:00"))],
            note: "在宅"
        )

        try await client.updateWorkRecord(date: "2026-10-01", update)

        #expect(transport.requests[0].httpMethod == "PUT")
        #expect(transport.requests[0].url?.absoluteString == "https://api.freee.co.jp/hr/api/v1/employees/20/work_records/2026-10-01")
        let body = transport.bodyJSON(0)
        #expect(body["company_id"] as? Int == 10)
        #expect(body["work_record_segments"] as? [[String: String]] == [
            ["clock_in_at": "2026-10-01 18:00:00", "clock_out_at": "2026-10-02 03:00:00"]
        ])
        #expect(body["break_records"] as? [[String: String]] == [
            ["clock_in_at": "2026-10-01 20:00:00", "clock_out_at": "2026-10-01 21:00:00"]
        ])
        #expect(body["note"] as? String == "在宅")
    }

    @Test func アクセストークンの期限が切れていたら更新してから呼び出す() async throws {
        let transport = FakeTransport([
            .init(status: 200, body: tokenJSON),
            .init(status: 200, body: "[]"),
        ])
        let store = MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(-10)))
        let client = makeClient(transport, store)

        _ = try await client.timeClocks(from: "2026-09-30", to: "2026-10-02")

        #expect(transport.requests[0].url?.absoluteString == "https://accounts.secure.freee.co.jp/public_api/token")
        #expect(transport.bodyString(0).contains("grant_type=refresh_token"))
        #expect(transport.bodyString(0).contains("refresh_token=old-refresh"))
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
        #expect(store.credentials?.accessToken == "new-access")
        #expect(store.credentials?.refreshToken == "new-refresh")
        #expect(store.credentials?.expiresAt == now.addingTimeInterval(21600))
    }

    @Test func 認証エラーが返ったらトークンを更新して1回だけやり直す() async throws {
        let transport = FakeTransport([
            .init(status: 401, body: #"{"message":"ログインをしてください。"}"#),
            .init(status: 200, body: tokenJSON),
            .init(status: 200, body: "[]"),
        ])
        let store = MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(3600)))
        let client = makeClient(transport, store)

        _ = try await client.timeClocks(from: "2026-09-30", to: "2026-10-02")

        #expect(transport.requests.count == 3)
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
    }

    @Test func トークンの更新に失敗したら再連携が必要なエラーにする() async throws {
        let transport = FakeTransport([
            .init(status: 401, body: #"{"error":"invalid_grant","error_description":"期限切れです"}"#)
        ])
        let client = makeClient(transport, MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(-10))))

        await #expect(throws: FreeeError.reauthorizationRequired) {
            try await client.timeClocks(from: "2026-09-30", to: "2026-10-02")
        }
    }

    @Test func APIのエラーメッセージを取り出す() async throws {
        let transport = FakeTransport([
            .init(status: 400, body: #"{"status_code":400,"errors":[{"type":"bad_request","messages":["打刻の種類が正しくありません。"]}]}"#)
        ])
        let client = makeClient(transport, MemoryCredentialStore(credentials(expiresAt: now.addingTimeInterval(3600))))

        await #expect(throws: FreeeError.api(status: 400, message: "打刻の種類が正しくありません。")) {
            try await client.postTimeClock(type: .clockIn, baseDate: nil)
        }
    }

    @Test func 連携情報が無ければ未設定のエラーにする() async throws {
        let client = makeClient(FakeTransport([]), MemoryCredentialStore(nil))

        await #expect(throws: FreeeError.notConfigured) {
            try await client.timeClocks(from: "2026-09-30", to: "2026-10-02")
        }
    }
}

@Suite struct OAuthTests {
    let now = jst("2026-10-02 08:50")

    @Test func 認可ページのURLを作る() {
        let url = OAuth.authorizeURL(clientID: "cid")

        #expect(url.absoluteString == "https://accounts.secure.freee.co.jp/public_api/authorize?response_type=code&client_id=cid&redirect_uri=urn:ietf:wg:oauth:2.0:oob&prompt=select_company")
    }

    @Test func 認可コードをトークンに交換し事業所と従業員を取得する() async throws {
        let transport = FakeTransport([
            .init(status: 200, body: #"{"access_token":"a1","token_type":"bearer","expires_in":21600,"refresh_token":"r1","scope":"read write","created_at":1790898600,"company_id":10}"#),
            .init(status: 200, body: #"{"id":1,"companies":[{"id":99,"name":"別の事業所","role":"self_only","employee_id":5},{"id":10,"name":"テスト","role":"self_only","employee_id":20,"display_name":"hyonny"}]}"#),
        ])
        let now = now

        let credentials = try await OAuth.authorize(
            clientID: "cid",
            clientSecret: "secret",
            code: " abc123\n",
            transport: transport,
            now: { now }
        )

        #expect(credentials == Credentials(
            clientID: "cid",
            clientSecret: "secret",
            accessToken: "a1",
            refreshToken: "r1",
            expiresAt: now.addingTimeInterval(21600),
            companyID: 10,
            employeeID: 20
        ))
        #expect(transport.bodyString(0).contains("grant_type=authorization_code"))
        #expect(transport.bodyString(0).contains("code=abc123"))
        #expect(transport.bodyString(0).contains("redirect_uri=urn%3Aietf%3Awg%3Aoauth%3A2.0%3Aoob"))
        #expect(transport.requests[1].url?.absoluteString == "https://api.freee.co.jp/hr/api/v1/users/me")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer a1")
    }

    @Test func 従業員情報が無い事業所なら連携できないエラーにする() async throws {
        let transport = FakeTransport([
            .init(status: 200, body: #"{"access_token":"a1","token_type":"bearer","expires_in":21600,"refresh_token":"r1","company_id":10}"#),
            .init(status: 200, body: #"{"id":1,"companies":[{"id":10,"name":"テスト","role":"self_only","employee_id":null}]}"#),
        ])
        let now = now

        await #expect(throws: FreeeError.employeeNotFound) {
            try await OAuth.authorize(clientID: "cid", clientSecret: "secret", code: "abc", transport: transport, now: { now })
        }
    }
}

@Suite struct FreeeDateTests {
    @Test(arguments: [
        "2026-10-01T09:00:00.000+09:00",
        "2026-10-01T09:00:00+09:00",
        "2026-10-01T00:00:00Z",
        "2026-10-01 09:00:00",
        "2026-10-01 09:00",
    ])
    func freeeが返す日時の形式を解釈する(_ string: String) {
        #expect(JST.parse(string) == jst("2026-10-01 09:00"))
    }

    @Test func 日付文字列は日本時間で作る() {
        #expect(JST.dateString(jst("2026-10-02 00:30")) == "2026-10-02")
        #expect(JST.dateTimeString(jst("2026-10-02 03:00")) == "2026-10-02 03:00:00")
    }
}
