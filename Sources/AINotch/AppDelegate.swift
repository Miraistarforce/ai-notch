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
    private let timestampFormatter = ISO8601DateFormatter()

    private lazy var settingsController = SettingsWindowController(port: port)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // .app内のhookスクリプトを ~/Library/Application Support/AINotch/hooks へ同期
        // （連携設定はこのパスを各AIの設定ファイルに書き込む）
        HookSetup.shared.syncBundledScripts()

        // --enable-login-item / --disable-login-item で自動起動をGUIなしに切り替える
        LoginItem.shared.applyLaunchArguments(CommandLine.arguments)

        store = SessionStore()
        windowController = NotchWindowController(store: store)
        store.onChange = { [weak self] in
            self?.windowController.refreshPin()
        }
        windowController.show()

        // アプリ切り替えを監視：点滅中のセッションの画面を開いたら点滅を解除し、
        // 逆に画面から離れたら（未対応の承認待ちがあれば）パネルを開き直す
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.store.frontmostChanged(app)
        }

        do {
            let server = try EventServer(port: port)
            server.onEvent = { [weak self] dict in
                DispatchQueue.main.async {
                    guard let self else { return }
                    var rec = dict
                    rec["received_at"] = self.timestampFormatter.string(from: Date())
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
            server.decisionProvider = { [weak self] sid in
                var decision = "pending"
                if let self {
                    DispatchQueue.main.sync {
                        decision = self.store.takeDecision(sid) ?? "pending"
                    }
                }
                return decision
            }
            server.decisionSetter = { [weak self] sid, decision in
                DispatchQueue.main.async { self?.store.decide(sid, decision: decision) }
            }
            server.debugProvider = { [weak self] in
                var data = Data("{}".utf8)
                if let self {
                    DispatchQueue.main.sync { data = self.windowController.debugJSON() }
                }
                return data
            }
            // 待受開始のログは .ready を受け取ってから出す（startした時点では未確定）
            server.onStateChange = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    NSLog("AINotch: 127.0.0.1:\(self.port) で待受開始")
                case .waiting(let error):
                    CrashLog.note("サーバーが待機状態のままです（ポート\(self.port)）: \(error)")
                case .failed(let error):
                    CrashLog.note("サーバーが停止しました（ポート\(self.port)）: \(error)")
                default:
                    break
                }
            }
            server.start()
            self.server = server
        } catch {
            // ここで終了はしない（黙って消えるのが今回直した問題そのもの）。
            // 理由をログに残し、メニューバーからは操作できる状態を保つ。
            CrashLog.note("サーバーを起動できませんでした（ポート\(port)）: \(error)")
        }

        setupStatusItem()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.windowController.reposition()
        }

        // 診断用：わざと落として「crash.logに理由が残るか」「launchdが復帰させるか」を確かめる。
        // `open dist/AINotch.app --args --selftest-exception` で実行する。
        if CommandLine.arguments.contains("--selftest-exception") {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                NSException(
                    name: .internalInconsistencyException,
                    reason: "AI Notch セルフテスト：意図的に投げた例外です",
                    userInfo: ["selftest": true]
                ).raise()
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.clawdMenuIcon()
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "AI Notch — クリックで連携設定"
        statusItem = item
    }

    /// 左クリック＝連携設定を開く、右クリック＝ユーティリティメニュー
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let info = NSMenuItem(title: "AI Notch — ポート \(port) で待受中", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "AI連携の設定を開く…", action: #selector(openSettings), keyEquivalent: ","))
            let login = NSMenuItem(title: "ログイン時に自動起動", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.state = LoginItem.shared.isEnabled ? .on : .off
            login.isEnabled = LoginItem.shared.isAvailable
            menu.addItem(login)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "テストイベントを表示", action: #selector(sendTestEvent), keyEquivalent: "t"))
            menu.addItem(NSMenuItem(title: "完了済みセッションを消去", action: #selector(clearDone), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "アクセシビリティ設定を開く（キー送信に必要）", action: #selector(openAccessibility), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "AI Notch を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            for mi in menu.items where mi.action != nil { mi.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
        } else {
            openSettings()
        }
    }

    @objc private func openSettings() {
        settingsController.open()
    }

    /// メニューからの自動起動オン/オフ。失敗（macOSの承認待ち等）は理由をアラートで出す。
    @objc private func toggleLaunchAtLogin() {
        let item = LoginItem.shared
        guard item.isAvailable else { return }
        do {
            try item.setEnabled(!item.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "自動起動を設定できませんでした"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "ログイン項目を開く")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { item.openSystemSettings() }
        }
    }

    /// メニューバー用のClawdアイコン（ClawdSpriteと同じピクセル配置）
    private static func clawdMenuIcon(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let unit = size / 15.0
            let body = NSColor(calibratedRed: 0xDE / 255.0, green: 0x88 / 255.0, blue: 0x6D / 255.0, alpha: 1)
            func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
                color.setFill()
                NSRect(x: x * unit, y: size - (y + h) * unit, width: w * unit, height: h * unit).fill()
            }
            // 足4本
            px(3, 11, 1, 4, body)
            px(5, 11, 1, 4, body)
            px(9, 11, 1, 4, body)
            px(11, 11, 1, 4, body)
            // 胴体
            px(2, 6, 11, 7, body)
            // 腕
            px(0, 9, 2, 2, body)
            px(13, 9, 2, 2, body)
            // 目
            px(4, 8, 1, 2, .black)
            px(10, 8, 1, 2, .black)
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func sendTestEvent() {
        // 同一フォルダで2エージェント（グループ枠のデモ）＋ 別フォルダでエラー（赤点滅のデモ）
        let folder = "/Users/you/proj/mac-ai-notch"
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
            "cwd": "/Users/you/proj/backend",
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
