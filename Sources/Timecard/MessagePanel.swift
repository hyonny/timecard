import AppKit
import SwiftUI

/// 出勤ボタンのすぐ横に出す、矢印なしの小さなメッセージ。
/// ボタンは Dock の列（アプリ用の表示領域の外）に置かれるため、NSPopover では位置がずれる
@MainActor
final class MessagePanel {
    private final class KeyablePanel: NSPanel {
        // 中の「再取得」ボタンを1回のクリックで押せるようにする
        override var canBecomeKey: Bool { true }
    }

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var closeTask: Task<Void, Never>?

    var isShown: Bool { panel != nil }

    func show(_ view: MessageView, beside anchor: NSWindow, autoCloseAfter seconds: Double? = nil) {
        close()

        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = anchor.level
        panel.collectionBehavior = anchor.collectionBehavior
        panel.contentView = background
        panel.setFrameOrigin(Self.origin(for: size, beside: anchor))
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        self.panel = panel

        // パネルの外をクリックしたら閉じる。他アプリ上のクリックはグローバル、自アプリ内はローカルの監視で受ける
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self, weak anchor] event in
            // 出勤ボタン上のクリックは PanelController が開閉を切り替える
            if event.window !== self?.panel, event.window !== anchor {
                self?.close()
            }
            return event
        }) {
            monitors.append(local)
        }

        if let seconds {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled {
                    self?.close()
                }
            }
        }
    }

    func close() {
        closeTask?.cancel()
        closeTask = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }

    /// ボタンの右隣に、上端をそろえて置く。右に入りきらなければ左隣に置く
    private static func origin(for size: NSSize, beside anchor: NSWindow) -> NSPoint {
        let gap: CGFloat = 2
        let margin: CGFloat = 6
        let screen = (anchor.screen ?? NSScreen.main)?.frame ?? anchor.frame
        var x = anchor.frame.maxX + gap
        if x + size.width > screen.maxX - margin {
            x = anchor.frame.minX - gap - size.width
        }
        // ボタンのタイルは枠の内側に余白を持つので、その分だけ下げて上端をそろえる
        var y = anchor.frame.maxY - margin - size.height
        y = max(screen.minY + margin, min(y, screen.maxY - margin - size.height))
        return NSPoint(x: x, y: y)
    }
}
