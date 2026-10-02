import Foundation

public actor FreeeClient: FreeeAPI {
    private let store: any CredentialStore
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        store: any CredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.transport = transport
        self.now = now
    }

    public func timeClocks(from: String, to: String) async throws -> [TimeClock] {
        let data = try await call { credentials in
            Self.request(
                "GET",
                "/employees/\(credentials.employeeID)/time_clocks",
                query: [
                    ("company_id", "\(credentials.companyID)"),
                    ("from_date", from),
                    ("to_date", to),
                    ("limit", "100"),
                ]
            )
        }
        return try OAuth.decode([TimeClockDTO].self, data).map { try $0.model() }
    }

    public func postTimeClock(type: ClockType, baseDate: String?) async throws -> TimeClock {
        let data = try await call { credentials in
            var body: [String: Any] = ["company_id": credentials.companyID, "type": type.rawValue]
            if let baseDate {
                body["base_date"] = baseDate
            }
            return Self.request("POST", "/employees/\(credentials.employeeID)/time_clocks", body: body)
        }
        return try OAuth.decode(TimeClockCreated.self, data).employeeTimeClock.model()
    }

    public func workRecord(date: String) async throws -> WorkRecord {
        let data = try await call { credentials in
            Self.request(
                "GET",
                "/employees/\(credentials.employeeID)/work_records/\(date)",
                query: [("company_id", "\(credentials.companyID)")]
            )
        }
        return try OAuth.decode(WorkRecordDTO.self, data).model(date: date)
    }

    public func updateWorkRecord(date: String, _ update: WorkRecordUpdate) async throws {
        _ = try await call { credentials in
            let ranges: ([TimeRange]) -> [[String: String]] = { ranges in
                ranges.map {
                    ["clock_in_at": JST.dateTimeString($0.start), "clock_out_at": JST.dateTimeString($0.end)]
                }
            }
            var body: [String: Any] = [
                "company_id": credentials.companyID,
                "work_record_segments": ranges(update.segments),
                "break_records": ranges(update.breakRecords),
            ]
            if let note = update.note {
                body["note"] = note
            }
            return Self.request("PUT", "/employees/\(credentials.employeeID)/work_records/\(date)", body: body)
        }
    }

    /// 有効なアクセストークンを付けて呼び出す。401 が返ったらトークンを更新して1回だけやり直す
    private func call(_ build: (Credentials) -> URLRequest) async throws -> Data {
        guard var credentials = try store.load() else {
            throw FreeeError.notConfigured
        }
        if credentials.expiresAt.addingTimeInterval(-60) <= now() {
            credentials = try await refresh(credentials)
        }
        var (data, response) = try await send(build(credentials), credentials)
        if response.statusCode == 401 {
            credentials = try await refresh(credentials)
            (data, response) = try await send(build(credentials), credentials)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FreeeError.api(status: response.statusCode, message: OAuth.errorMessage(data))
        }
        return data
    }

    private func send(_ request: URLRequest, _ credentials: Credentials) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        return try await transport.send(request)
    }

    /// freee のリフレッシュトークンは使うたびに新しいものへ置き換わるので、必ず保存し直す
    private func refresh(_ credentials: Credentials) async throws -> Credentials {
        let (data, response) = try await transport.send(OAuth.tokenRequest([
            ("grant_type", "refresh_token"),
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
            ("refresh_token", credentials.refreshToken),
        ]))
        guard response.statusCode == 200 else {
            throw FreeeError.reauthorizationRequired
        }
        let token = try OAuth.decode(TokenResponse.self, data)
        var updated = credentials
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken
        updated.expiresAt = now().addingTimeInterval(TimeInterval(token.expiresIn))
        try store.save(updated)
        return updated
    }

    private static func request(
        _ method: String,
        _ path: String,
        query: [(String, String)] = [],
        body: [String: Any]? = nil
    ) -> URLRequest {
        var components = URLComponents(string: OAuth.apiBase + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}

private func parseDate(_ string: String) throws -> Date {
    guard let date = JST.parse(string) else {
        throw FreeeError.invalidResponse("日時の形式: \(string)")
    }
    return date
}

private struct TimeClockDTO: Decodable {
    var date: String
    var type: ClockType
    var datetime: String

    func model() throws -> TimeClock {
        TimeClock(date: date, type: type, datetime: try parseDate(datetime))
    }
}

private struct TimeClockCreated: Decodable {
    var employeeTimeClock: TimeClockDTO

    enum CodingKeys: String, CodingKey {
        case employeeTimeClock = "employee_time_clock"
    }
}

private struct WorkRecordDTO: Decodable {
    struct Range: Decodable {
        var clockInAt: String
        var clockOutAt: String

        enum CodingKeys: String, CodingKey {
            case clockInAt = "clock_in_at"
            case clockOutAt = "clock_out_at"
        }
    }

    var clockInAt: String?
    var clockOutAt: String?
    var breakRecords: [Range]?
    var note: String?

    enum CodingKeys: String, CodingKey {
        case clockInAt = "clock_in_at"
        case clockOutAt = "clock_out_at"
        case breakRecords = "break_records"
        case note
    }

    func model(date: String) throws -> WorkRecord {
        WorkRecord(
            date: date,
            clockInAt: try clockInAt.map(parseDate),
            clockOutAt: try clockOutAt.map(parseDate),
            breakRecords: try (breakRecords ?? []).map {
                TimeRange(start: try parseDate($0.clockInAt), end: try parseDate($0.clockOutAt))
            },
            note: note
        )
    }
}
