import Foundation
@testable import TimecardCore

/// "2026-10-02 08:50" 形式（JST）から Date を作る
func jst(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: string)!
}

enum APICall: Equatable {
    case timeClocks(from: String, to: String)
    case post(ClockType, baseDate: String?)
    case getRecord(String)
    case put(String, WorkRecordUpdate)
}

/// freee の代わりに使う、打刻と勤怠をメモリ上に持つ API
final class FakeFreeeAPI: FreeeAPI, @unchecked Sendable {
    var clocks: [TimeClock] = []
    var records: [String: WorkRecord] = [:]
    var now: Date
    /// 勤怠を書き換えただけでは出勤打刻を受け付けない挙動（退勤打刻が必要）を再現する
    var requiresClockOutPunch = false
    var putError: FreeeError?
    var clockInError: FreeeError?
    private(set) var calls: [APICall] = []
    private var openDatesNeedingPunch: Set<String> = []

    init(now: Date) {
        self.now = now
    }

    var writes: [APICall] {
        calls.filter {
            switch $0 {
            case .post, .put: true
            default: false
            }
        }
    }

    func markOpen(date: String) {
        openDatesNeedingPunch.insert(date)
    }

    func timeClocks(from: String, to: String) async throws -> [TimeClock] {
        calls.append(.timeClocks(from: from, to: to))
        return clocks
    }

    func postTimeClock(type: ClockType, baseDate: String?) async throws -> TimeClock {
        calls.append(.post(type, baseDate: baseDate))
        if type == .clockIn {
            if let clockInError { throw clockInError }
            if requiresClockOutPunch, !openDatesNeedingPunch.isEmpty {
                throw FreeeError.api(status: 400, message: "退勤打刻が必要です。")
            }
        }
        if type == .clockOut, let baseDate {
            openDatesNeedingPunch.remove(baseDate)
        }
        let clock = TimeClock(date: baseDate ?? JST.dateString(now), type: type, datetime: now)
        clocks.append(clock)
        return clock
    }

    func workRecord(date: String) async throws -> WorkRecord {
        calls.append(.getRecord(date))
        return records[date] ?? WorkRecord(date: date)
    }

    func updateWorkRecord(date: String, _ update: WorkRecordUpdate) async throws {
        calls.append(.put(date, update))
        if let putError { throw putError }
        records[date] = WorkRecord(
            date: date,
            clockInAt: update.segments.first?.start,
            clockOutAt: update.segments.last?.end,
            breakRecords: update.breakRecords,
            note: update.note
        )
    }
}
