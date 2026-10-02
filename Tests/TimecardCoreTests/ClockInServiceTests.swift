import Foundation
import Testing
@testable import TimecardCore

@Suite struct ClockInServiceTests {
    let now = jst("2026-10-02 08:50")

    func makeService(_ api: FakeFreeeAPI) -> ClockInService {
        let now = api.now
        return ClockInService(api: api, now: { now })
    }

    /// 前日 09:00 に出勤したまま退勤していない状態
    func apiWithOpenShift(clockIn: String = "2026-10-01 09:00", date: String = "2026-10-01") -> FakeFreeeAPI {
        let api = FakeFreeeAPI(now: now)
        api.clocks = [TimeClock(date: date, type: .clockIn, datetime: jst(clockIn))]
        api.records[date] = WorkRecord(date: date, clockInAt: jst(clockIn))
        api.markOpen(date: date)
        return api
    }

    @Test func 打刻が無ければ出勤だけ打刻する() async throws {
        let api = FakeFreeeAPI(now: now)

        let outcome = try await makeService(api).clockIn()

        #expect(outcome == .clockedIn(at: now))
        #expect(api.writes == [.post(.clockIn, baseDate: nil)])
    }

    @Test func 直近3日分の打刻を取得する() async throws {
        let api = FakeFreeeAPI(now: now)

        _ = try await makeService(api).clockIn()

        #expect(api.calls.first == .timeClocks(from: "2026-09-30", to: "2026-10-02"))
    }

    @Test func 前日に退勤打刻があれば出勤だけ打刻する() async throws {
        let api = FakeFreeeAPI(now: now)
        api.clocks = [
            TimeClock(date: "2026-10-01", type: .clockIn, datetime: jst("2026-10-01 09:00")),
            TimeClock(date: "2026-10-01", type: .clockOut, datetime: jst("2026-10-01 18:00")),
        ]

        let outcome = try await makeService(api).clockIn()

        #expect(outcome == .clockedIn(at: now))
        #expect(api.writes == [.post(.clockIn, baseDate: nil)])
    }

    @Test func 前日の勤怠に退勤時刻が入っていれば書き換えずに出勤する() async throws {
        let api = apiWithOpenShift()
        api.records["2026-10-01"] = WorkRecord(
            date: "2026-10-01",
            clockInAt: jst("2026-10-01 09:00"),
            clockOutAt: jst("2026-10-01 18:00")
        )

        let outcome = try await makeService(api).clockIn()

        #expect(outcome == .clockedIn(at: now))
        #expect(api.writes == [.post(.clockIn, baseDate: nil)])
    }

    @Test func 前日が退勤していなければ出勤の9時間後で退勤を補完してから出勤する() async throws {
        let api = apiWithOpenShift()

        let outcome = try await makeService(api).clockIn()

        let expected = WorkRecordUpdate(
            segments: [TimeRange(start: jst("2026-10-01 09:00"), end: jst("2026-10-01 18:00"))],
            breakRecords: [],
            note: nil
        )
        #expect(outcome == .closedPreviousAndClockedIn(previousClockOut: jst("2026-10-01 18:00"), at: now))
        #expect(api.writes == [.put("2026-10-01", expected), .post(.clockIn, baseDate: nil)])
    }

    @Test func 補完するとき既存の休憩とメモをそのまま送り返す() async throws {
        let api = apiWithOpenShift()
        let rest = TimeRange(start: jst("2026-10-01 12:00"), end: jst("2026-10-01 13:00"))
        api.records["2026-10-01"] = WorkRecord(
            date: "2026-10-01",
            clockInAt: jst("2026-10-01 09:00"),
            breakRecords: [rest],
            note: "在宅"
        )

        _ = try await makeService(api).clockIn()

        guard case .put(_, let update) = api.writes.first else {
            Issue.record("勤怠の更新が呼ばれていない")
            return
        }
        #expect(update.breakRecords == [rest])
        #expect(update.note == "在宅")
    }

    @Test func 退勤が翌日にまたがっても出勤日の勤怠を更新する() async throws {
        let api = apiWithOpenShift(clockIn: "2026-10-01 18:00")
        api.now = jst("2026-10-02 09:00")

        let outcome = try await makeService(api).clockIn()

        let expected = WorkRecordUpdate(
            segments: [TimeRange(start: jst("2026-10-01 18:00"), end: jst("2026-10-02 03:00"))],
            breakRecords: [],
            note: nil
        )
        #expect(outcome == .closedPreviousAndClockedIn(previousClockOut: jst("2026-10-02 03:00"), at: api.now))
        #expect(api.writes.first == .put("2026-10-01", expected))
    }

    @Test func 勤怠の書き換えだけでは出勤が拒否されるとき退勤打刻を経由して補完する() async throws {
        let api = apiWithOpenShift()
        api.requiresClockOutPunch = true

        let outcome = try await makeService(api).clockIn()

        let expected = WorkRecordUpdate(
            segments: [TimeRange(start: jst("2026-10-01 09:00"), end: jst("2026-10-01 18:00"))],
            breakRecords: [],
            note: nil
        )
        #expect(outcome == .closedPreviousAndClockedIn(previousClockOut: jst("2026-10-01 18:00"), at: now))
        #expect(api.writes == [
            .put("2026-10-01", expected),
            .post(.clockIn, baseDate: nil),
            .post(.clockOut, baseDate: "2026-10-01"),
            .put("2026-10-01", expected),
            .post(.clockIn, baseDate: nil),
        ])
    }

    @Test func 前回の出勤から9時間たっていなければ何も書き込まない() async throws {
        let api = apiWithOpenShift(clockIn: "2026-10-01 23:00")
        api.now = jst("2026-10-02 07:00")

        let outcome = try await makeService(api).clockIn()

        #expect(outcome == .alreadyWorking(since: jst("2026-10-01 23:00")))
        #expect(api.writes.isEmpty)
    }

    @Test func 当日すでに出勤していれば何も書き込まない() async throws {
        let api = FakeFreeeAPI(now: jst("2026-10-02 19:00"))
        api.clocks = [TimeClock(date: "2026-10-02", type: .clockIn, datetime: jst("2026-10-02 08:50"))]

        let outcome = try await makeService(api).clockIn()

        #expect(outcome == .alreadyWorking(since: jst("2026-10-02 08:50")))
        #expect(api.writes.isEmpty)
    }

    @Test func 朝5時より前は前日の出勤を当日の出勤として扱い何も書き込まない() async throws {
        let api = FakeFreeeAPI(now: jst("2026-10-03 00:30"))
        api.clocks = [TimeClock(date: "2026-10-02", type: .clockIn, datetime: jst("2026-10-02 09:10"))]
        api.records["2026-10-02"] = WorkRecord(date: "2026-10-02", clockInAt: jst("2026-10-02 09:10"))

        let outcome = try await makeService(api).clockIn()

        #expect(outcome == .alreadyWorking(since: jst("2026-10-02 09:10")))
        #expect(api.writes.isEmpty)
    }

    @Test(arguments: [
        ("2026-10-03 04:59", TodayStatus.clockedIn(at: jst("2026-10-02 09:10"))),
        ("2026-10-03 05:00", TodayStatus.notClockedIn),
    ])
    func 出勤済みの表示は朝5時に切り替わる(now: String, expected: TodayStatus) async throws {
        let api = FakeFreeeAPI(now: jst(now))
        api.clocks = [TimeClock(date: "2026-10-02", type: .clockIn, datetime: jst("2026-10-02 09:10"))]

        let status = try await makeService(api).currentStatus()

        #expect(status == expected)
    }

    @Test func 朝5時より前でも当日の日付までの打刻を取得する() async throws {
        let api = FakeFreeeAPI(now: jst("2026-10-03 00:30"))

        _ = try await makeService(api).currentStatus()

        #expect(api.calls.first == .timeClocks(from: "2026-09-30", to: "2026-10-03"))
    }

    @Test func 退勤の補完に失敗したら出勤を打刻しない() async throws {
        let api = apiWithOpenShift()
        api.putError = .api(status: 403, message: "アクセス権限がありません。")

        await #expect(throws: FreeeError.api(status: 403, message: "アクセス権限がありません。")) {
            try await makeService(api).clockIn()
        }
        #expect(!api.writes.contains(.post(.clockIn, baseDate: nil)))
    }

    @Test func 出勤打刻がサーバーエラーなら退勤打刻の経路に進まない() async throws {
        let api = apiWithOpenShift()
        api.clockInError = .api(status: 500, message: "エラーが発生しました。")

        await #expect(throws: FreeeError.api(status: 500, message: "エラーが発生しました。")) {
            try await makeService(api).clockIn()
        }
        #expect(!api.writes.contains(.post(.clockOut, baseDate: "2026-10-01")))
    }

    @Test func 当日の出勤打刻があれば出勤済みと判定する() async throws {
        let api = FakeFreeeAPI(now: now)
        api.clocks = [
            TimeClock(date: "2026-10-01", type: .clockIn, datetime: jst("2026-10-01 09:00")),
            TimeClock(date: "2026-10-02", type: .clockIn, datetime: jst("2026-10-02 08:30")),
        ]

        let status = try await makeService(api).currentStatus()

        #expect(status == .clockedIn(at: jst("2026-10-02 08:30")))
    }

    @Test func 当日の出勤打刻が無ければ未出勤と判定する() async throws {
        let api = apiWithOpenShift()

        let status = try await makeService(api).currentStatus()

        #expect(status == .notClockedIn)
    }
}
