import Foundation

public enum ClockInOutcome: Equatable, Sendable {
    case clockedIn(at: Date)
    case closedPreviousAndClockedIn(previousClockOut: Date, at: Date)
    case alreadyWorking(since: Date)
}

public enum TodayStatus: Equatable, Sendable {
    case notClockedIn
    case clockedIn(at: Date)
}

public struct ClockInService: Sendable {
    /// 退勤を補完するときの、出勤から退勤までの長さ（勤務8h＋休憩1h）
    public static let shiftLength: TimeInterval = 9 * 60 * 60

    private let api: any FreeeAPI
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    public init(
        api: any FreeeAPI,
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.api = api
        self.now = now
        self.log = log
    }

    public func currentStatus() async throws -> TodayStatus {
        let current = now()
        let clocks = try await recentClocks(current)
        if let todayIn = clockInOfToday(clocks, current) {
            return .clockedIn(at: todayIn.datetime)
        }
        return .notClockedIn
    }

    public func clockIn() async throws -> ClockInOutcome {
        let current = now()
        let clocks = try await recentClocks(current)

        if let todayIn = clockInOfToday(clocks, current) {
            return .alreadyWorking(since: todayIn.datetime)
        }
        guard let lastIn = clocks.last(where: { $0.type == .clockIn }) else {
            return .clockedIn(at: try await punchIn())
        }
        if clocks.contains(where: { $0.type == .clockOut && $0.datetime >= lastIn.datetime }) {
            return .clockedIn(at: try await punchIn())
        }
        // 自動退勤や手修正で、打刻が無くても勤怠に退勤時刻が入っていることがある
        let record = try await api.workRecord(date: lastIn.date)
        if record.clockOutAt != nil {
            return .clockedIn(at: try await punchIn())
        }

        let start = record.clockInAt ?? lastIn.datetime
        let end = start.addingTimeInterval(Self.shiftLength)
        if end > current {
            return .alreadyWorking(since: start)
        }

        try await closeRecord(record, date: lastIn.date, start: start, end: end)
        do {
            let at = try await punchIn()
            log("退勤を補完: \(lastIn.date) の勤怠を更新して出勤（経路A）")
            return .closedPreviousAndClockedIn(previousClockOut: end, at: at)
        } catch FreeeError.api(status: 400, let message) {
            // 勤怠を書き換えても退勤打刻が無いと出勤できない場合は、
            // 今の時刻で退勤を打刻し、退勤時刻を書き直してから出勤する。
            // 書き直しに失敗したら、当日の出勤を重ねずにそこで止める
            log("経路Aの出勤が拒否された（\(message)）。退勤打刻を経由する（経路B）")
            _ = try await api.postTimeClock(type: .clockOut, baseDate: lastIn.date)
            let latest = try await api.workRecord(date: lastIn.date)
            try await closeRecord(latest, date: lastIn.date, start: start, end: end)
            let at = try await punchIn()
            log("退勤を補完: \(lastIn.date) を退勤打刻のあと勤怠更新（経路B）")
            return .closedPreviousAndClockedIn(previousClockOut: end, at: at)
        }
    }

    private func recentClocks(_ current: Date) async throws -> [TimeClock] {
        let from = JST.calendar.date(byAdding: .day, value: -2, to: current) ?? current
        let clocks = try await api.timeClocks(from: JST.workdayString(from), to: JST.dateString(current))
        return clocks.sorted { $0.datetime < $1.datetime }
    }

    /// いまの勤務日（朝5時始まり）に打たれた出勤打刻
    private func clockInOfToday(_ clocks: [TimeClock], _ current: Date) -> TimeClock? {
        let today = JST.workdayString(current)
        return clocks.first { $0.type == .clockIn && JST.workdayString($0.datetime) == today }
    }

    private func punchIn() async throws -> Date {
        try await api.postTimeClock(type: .clockIn, baseDate: nil).datetime
    }

    private func closeRecord(_ record: WorkRecord, date: String, start: Date, end: Date) async throws {
        let update = WorkRecordUpdate(
            segments: [TimeRange(start: start, end: end)],
            breakRecords: record.breakRecords,
            note: record.note
        )
        try await api.updateWorkRecord(date: date, update)
    }
}
