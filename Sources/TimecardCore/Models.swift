import Foundation

public enum ClockType: String, Codable, Sendable {
    case clockIn = "clock_in"
    case breakBegin = "break_begin"
    case breakEnd = "break_end"
    case clockOut = "clock_out"
}

public struct TimeClock: Equatable, Sendable {
    /// 打刻日（YYYY-MM-DD）。日をまたいだ退勤では出勤日が入る
    public var date: String
    public var type: ClockType
    public var datetime: Date

    public init(date: String, type: ClockType, datetime: Date) {
        self.date = date
        self.type = type
        self.datetime = datetime
    }
}

public struct TimeRange: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct WorkRecord: Equatable, Sendable {
    public var date: String
    public var clockInAt: Date?
    public var clockOutAt: Date?
    public var breakRecords: [TimeRange]
    public var note: String?

    public init(
        date: String,
        clockInAt: Date? = nil,
        clockOutAt: Date? = nil,
        breakRecords: [TimeRange] = [],
        note: String? = nil
    ) {
        self.date = date
        self.clockInAt = clockInAt
        self.clockOutAt = clockOutAt
        self.breakRecords = breakRecords
        self.note = note
    }
}

public struct WorkRecordUpdate: Equatable, Sendable {
    public var segments: [TimeRange]
    public var breakRecords: [TimeRange]
    public var note: String?

    public init(segments: [TimeRange], breakRecords: [TimeRange], note: String?) {
        self.segments = segments
        self.breakRecords = breakRecords
        self.note = note
    }
}

public struct Credentials: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var companyID: Int
    public var employeeID: Int

    public init(
        clientID: String,
        clientSecret: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        companyID: Int,
        employeeID: Int
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.companyID = companyID
        self.employeeID = employeeID
    }
}

public enum FreeeError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case reauthorizationRequired
    case employeeNotFound
    case api(status: Int, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "freee との連携が未設定です。右クリックの「設定」から連携してください。"
        case .reauthorizationRequired:
            "freee の認証が切れました。右クリックの「設定」から連携し直してください。"
        case .employeeNotFound:
            "この事業所に従業員情報が見つかりません。"
        case .api(let status, let message):
            "freee がエラーを返しました（\(status)）: \(message)"
        case .invalidResponse(let detail):
            "freee の応答を解釈できませんでした: \(detail)"
        }
    }
}

public protocol FreeeAPI: Sendable {
    func timeClocks(from: String, to: String) async throws -> [TimeClock]
    func postTimeClock(type: ClockType, baseDate: String?) async throws -> TimeClock
    func workRecord(date: String) async throws -> WorkRecord
    func updateWorkRecord(date: String, _ update: WorkRecordUpdate) async throws
}

/// freee 人事労務の日時は日本時間で扱う
public enum JST {
    public static let timeZone = TimeZone(identifier: "Asia/Tokyo")!

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// YYYY-MM-DD
    public static func dateString(_ date: Date) -> String {
        formatter("yyyy-MM-dd").string(from: date)
    }

    /// 勤務日の境目は朝5時。5時より前は前日の勤務日として扱う
    public static let workdayStartHour = 5

    /// その時刻が属する勤務日（YYYY-MM-DD）
    public static func workdayString(_ date: Date) -> String {
        dateString(date.addingTimeInterval(TimeInterval(-workdayStartHour * 3600)))
    }

    /// YYYY-MM-DD HH:MM:SS（勤怠の更新 API が受け付ける形式）
    public static func dateTimeString(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss").string(from: date)
    }

    public static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(string, strategy: .iso8601) {
            return date
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            if let date = formatter(format).date(from: string) {
                return date
            }
        }
        return nil
    }
}
