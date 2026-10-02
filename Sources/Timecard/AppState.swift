import AppKit
import Foundation
import Observation
import TimecardCore

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        /// 起動直後で、まだ freee の状態を取得していない
        case loading
        /// freee との連携が未設定
        case needsSetup
        /// 未出勤。ボタンを押せる
        case ready
        /// 打刻の処理中
        case busy
        /// 当日出勤済み
        case working(since: Date)
        case failed(message: String)
    }

    private(set) var phase: Phase = .loading
    /// 打刻のあとに一度だけ見せるお知らせ（退勤を補完した、など）
    private(set) var notice: String?
    var isHovering = false
    var isPressed = false

    private let store: any CredentialStore
    private let service: ClockInService

    init(store: any CredentialStore = KeychainCredentialStore()) {
        self.store = store
        self.service = ClockInService(api: FreeeClient(store: store), log: { FileLog.append($0) })
    }

    /// 再設定のときに入力欄へ戻す、保存済みの Client ID と Client Secret
    var savedClient: (id: String, secret: String)? {
        guard let credentials = try? store.load() else { return nil }
        return (credentials.clientID, credentials.clientSecret)
    }

    func refresh() async {
        guard phase != .busy else { return }
        do {
            guard try store.load() != nil else {
                phase = .needsSetup
                return
            }
            switch try await service.currentStatus() {
            case .notClockedIn: phase = .ready
            case .clockedIn(let at): phase = .working(since: at)
            }
        } catch {
            fail(error)
        }
    }

    func clockIn() async {
        guard phase == .ready else { return }
        phase = .busy
        notice = nil
        do {
            switch try await service.clockIn() {
            case .clockedIn(let at):
                FileLog.append("出勤を打刻: \(JST.dateTimeString(at))")
                phase = .working(since: at)
            case .closedPreviousAndClockedIn(let previousClockOut, let at):
                FileLog.append("出勤を打刻: \(JST.dateTimeString(at))（前回の退勤を \(JST.dateTimeString(previousClockOut)) で補完）")
                phase = .working(since: at)
                notice = "前回の退勤を \(Self.format(previousClockOut, "M/d HH:mm")) で記録し、出勤を打刻しました。"
            case .alreadyWorking(let since):
                if JST.workdayString(since) == JST.workdayString(Date()) {
                    phase = .working(since: since)
                } else {
                    phase = .failed(message: "前回の出勤（\(Self.format(since, "M/d HH:mm"))）から9時間たっていないため、打刻しませんでした。")
                }
            }
        } catch {
            fail(error)
        }
    }

    func clearNotice() {
        notice = nil
    }

    func openAuthorizePage(clientID: String) {
        NSWorkspace.shared.open(OAuth.authorizeURL(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func connect(clientID: String, clientSecret: String, code: String) async throws {
        let credentials = try await OAuth.authorize(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            code: code
        )
        try store.save(credentials)
        FileLog.append("freee と連携: company_id=\(credentials.companyID) employee_id=\(credentials.employeeID)")
        phase = .loading
        await refresh()
    }

    private func fail(_ error: any Error) {
        FileLog.append("エラー: \(error.localizedDescription)")
        if case FreeeError.notConfigured = error {
            phase = .needsSetup
        } else {
            phase = .failed(message: error.localizedDescription)
        }
    }

    static func format(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = JST.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// ~/Library/Logs/Timecard.log に追記する
enum FileLog {
    static let url = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Timecard.log")

    static func append(_ message: String) {
        let line = "\(JST.dateTimeString(Date())) \(message)\n"
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? Data(line.utf8).write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
