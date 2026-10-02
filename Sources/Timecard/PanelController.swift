import AppKit
import ServiceManagement
import SwiftUI

/// 出勤ボタンを載せる、枠なしの常駐パネル
@MainActor
final class PanelController: NSObject {
    private let state: AppState
    private let panel: NSPanel
    private let content: PanelContentView
    private let messagePanel = MessagePanel()
    private var setupWindow: NSWindow?

    init(state: AppState) {
        self.state = state
        let size = ClockButtonView.panelSize
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        content = PanelContentView(frame: NSRect(origin: .zero, size: size))
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        // 全デスクトップに出す。フルスクリーンのアプリ上には出さない
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: ClockButtonView(state: state))
        hosting.frame = content.bounds
        hosting.autoresizingMask = [.width, .height]
        content.addSubview(hosting)
        content.state = state
        content.onClick = { [weak self] in self?.handleClick() }
        content.onRightClick = { [weak self] event in self?.showMenu(event) }
        panel.contentView = content
    }

    func show() {
        // 位置を記憶していなければ、画面左上（メニューバーの下）に置く
        if !panel.setFrameUsingName("TimecardPanel"), let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX + 8, y: screen.visibleFrame.maxY - 8))
        }
        panel.setFrameAutosaveName("TimecardPanel")
        panel.orderFrontRegardless()
    }

    private func handleClick() {
        // メッセージを出しているあいだのクリックは、閉じる操作として扱う
        if messagePanel.isShown {
            messagePanel.close()
            return
        }
        switch state.phase {
        case .ready:
            Task {
                await state.clockIn()
                showResult()
            }
        case .working(let since):
            showMessage("\(AppState.format(since, "H:mm")) に出勤済みです。", isError: false)
        case .failed(let message):
            showMessage(message, isError: true)
        case .needsSetup:
            showSetup()
        case .loading, .busy:
            break
        }
    }

    /// 打刻のあと、お知らせかエラーがあればボタンの横に見せる
    private func showResult() {
        if case .failed(let message) = state.phase {
            showMessage(message, isError: true)
        } else if let notice = state.notice {
            showMessage(notice, isError: false, autoCloseAfter: 8)
            state.clearNotice()
        }
    }

    private func showMessage(_ message: String, isError: Bool, autoCloseAfter seconds: Double? = nil) {
        let view = MessageView(
            message: message,
            isError: isError,
            onRetry: isError
                ? { [weak self] in
                    self?.messagePanel.close()
                    Task { await self?.state.refresh() }
                }
                : nil
        )
        messagePanel.show(view, beside: panel, autoCloseAfter: seconds)
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(item("状態を再取得", #selector(refreshClicked)))
        menu.addItem(item("freee 連携の設定…", #selector(setupClicked)))
        let login = item("ログイン時に起動", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("終了", #selector(quitClicked)))
        NSMenu.popUpContextMenu(menu, with: event, for: content)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshClicked() {
        Task { await state.refresh() }
    }

    @objc private func setupClicked() {
        showSetup()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showMessage("ログイン時の起動を切り替えられませんでした: \(error.localizedDescription)", isError: false)
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "freee 連携の設定"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SetupView(state: state, onDone: { [weak window] in window?.close() })
            )
            window.center()
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }
}

/// クリックとドラッグ移動を見分けるため、マウス操作をまとめて受け取る
@MainActor
final class PanelContentView: NSView {
    var state: AppState?
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var mouseDownLocation: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        state?.isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        state?.isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        state?.isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let current = NSEvent.mouseLocation
        // 少しでも動かしたらクリックではなくウィンドウの移動として扱う
        if hypot(current.x - start.x, current.y - start.y) > 3 {
            mouseDownLocation = nil
            state?.isPressed = false
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        state?.isPressed = false
        guard mouseDownLocation != nil else { return }
        mouseDownLocation = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}
