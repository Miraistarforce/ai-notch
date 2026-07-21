import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: SessionStore!
    var server: EventServer?
    var windowController: NotchWindowController!
    var statusItem: NSStatusItem?
    let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["NOTCH_PORT"] ?? "") ?? 43110

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = SessionStore()
        windowController = NotchWindowController(store: store)
        store.onPendingChanged = { [weak self] in
            self?.windowController.refreshPin()
        }
        windowController.show()

        do {
            let server = try EventServer(port: port)
            server.onEvent = { [weak self] dict in
                DispatchQueue.main.async { self?.store.handle(dict) }
            }
            server.sessionsProvider = { [weak self] in
                var data = Data("[]".utf8)
                if let self {
                    DispatchQueue.main.sync { data = self.store.sessionsJSON() }
                }
                return data
            }
            server.debugProvider = { [weak self] in
                var data = Data("{}".utf8)
                if let self {
                    DispatchQueue.main.sync { data = self.windowController.debugJSON() }
                }
                return data
            }
            server.start()
            self.server = server
            NSLog("AINotch: 127.0.0.1:\(port) で待受開始")
        } catch {
            NSLog("AINotch: サーバー起動失敗 \(error)")
        }

        setupStatusItem()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.windowController.reposition()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🏝"
        let menu = NSMenu()

        let info = NSMenuItem(title: "AI Notch — ポート \(port) で待受中", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "テストイベントを表示", action: #selector(sendTestEvent), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "完了済みセッションを消去", action: #selector(clearDone), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "アクセシビリティ設定を開く（キー送信に必要）", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "AI Notch を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for mi in menu.items where mi.action != nil { mi.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func sendTestEvent() {
        store.handle([
            "event": "start",
            "session_id": "demo-1",
            "title": "認証バグの修正",
            "agent": "Claude",
            "term_program": "iTerm.app",
            "status": "middleware.ts を編集中",
        ])
        store.handle([
            "event": "start",
            "session_id": "demo-2",
            "title": "クエリの最適化",
            "agent": "Gemini",
            "term_program": "ghostty",
        ])
        store.handle([
            "hook_event_name": "PreToolUse",
            "session_id": "demo-1",
            "tool_name": "Edit",
            "tool_input": [
                "file_path": "src/auth/middleware.ts",
                "old_string": "jwt.verify(token);",
                "new_string": "if (!token) throw new AuthError('missing');\nreturn jwt.verify(token);",
            ],
        ])
        store.handle([
            "hook_event_name": "Notification",
            "session_id": "demo-1",
            "message": "Claude needs your permission to use Edit",
        ])
    }

    @objc private func clearDone() {
        store.clearFinished()
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
