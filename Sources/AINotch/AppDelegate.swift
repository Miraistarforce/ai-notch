import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: SessionStore!
    var server: EventServer?
    var windowController: NotchWindowController!
    var statusItem: NSStatusItem?
    let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["NOTCH_PORT"] ?? "") ?? 43110
    /// 受信イベントの履歴（デバッグ用、最新50件）
    private var recentEvents: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = SessionStore()
        windowController = NotchWindowController(store: store)
        store.onChange = { [weak self] in
            self?.windowController.refreshPin()
        }
        store.onFlash = { [weak self] in
            self?.windowController.flashOpen()
        }
        windowController.show()

        do {
            let server = try EventServer(port: port)
            server.onEvent = { [weak self] dict in
                DispatchQueue.main.async {
                    guard let self else { return }
                    var rec = dict
                    rec["received_at"] = ISO8601DateFormatter().string(from: Date())
                    self.recentEvents.append(rec)
                    if self.recentEvents.count > 50 { self.recentEvents.removeFirst() }
                    self.store.handle(dict)
                }
            }
            server.eventsProvider = { [weak self] in
                var data = Data("[]".utf8)
                if let self {
                    DispatchQueue.main.sync {
                        data = (try? JSONSerialization.data(withJSONObject: self.recentEvents, options: [.prettyPrinted])) ?? data
                    }
                }
                return data
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
        // 同一フォルダで2エージェント（グループ枠のデモ）＋ 別フォルダでエラー（赤点滅のデモ）
        let folder = "/Users/yohei/proj/mac-ai-notch"
        store.handle([
            "hook_event_name": "SessionStart",
            "session_id": "demo-1",
            "cwd": folder,
            "bundle_id": "com.todesktop.230313mzl4w4u92",
        ])
        store.handle([
            "event": "start",
            "session_id": "demo-2",
            "agent": "Codex",
            "cwd": folder,
            "status": "テストを実行中",
        ])
        store.handle([
            "hook_event_name": "PreToolUse",
            "session_id": "demo-1",
            "cwd": folder,
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
            "cwd": folder,
            "message": "Claude needs your permission to use Edit",
        ])
        store.handle([
            "event": "start",
            "session_id": "demo-3",
            "agent": "Gemini",
            "cwd": "/Users/yohei/proj/backend",
            "term_program": "ghostty",
        ])
        store.handle([
            "event": "error",
            "session_id": "demo-3",
            "status": "API制限で停止しました（デモ）",
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
