import AppKit
import ApplicationServices

/// ターミナルへのジャンプとキー送信（許可・拒否・選択肢回答）
enum TerminalControl {
    private static let workQueue = DispatchQueue(label: "ainotch.terminal")
    private static let osascriptTimeout: DispatchTimeInterval = .seconds(5)

    // MARK: - ジャンプ

    static func jump(_ s: AgentSession) {
        workQueue.async { _ = focus(s) }
    }

    /// セッションの画面を前面に出す。**ウィンドウ（タブ）単位で特定できたか**を返す。
    /// false＝アプリを前面にしただけで、どのウィンドウが前に来るかは分からない状態。
    @discardableResult
    private static func focus(_ s: AgentSession) -> Bool {
        if s.terminal == "iTerm", !s.itermUUID.isEmpty {
            runOsascript(itermJumpScript(uuid: s.itermUUID))
            return true
        }
        if s.terminal == "Terminal", !s.tty.isEmpty {
            runOsascript(terminalJumpScript(tty: s.tty))
            return true
        }
        // VS Code / Cursor はウィンドウタイトルの末尾がワークスペース名なので、それで特定する
        if FrontWindow.raiseWindow(bundleId: s.hostBundleId, containing: s.projectName) { return true }
        activateApp(for: s)
        return false
    }

    // MARK: - キー送信（要アクセシビリティ許可）

    /// 許可 = Return（デフォルトの「Yes」を選択）
    static func approve(_ s: AgentSession, requirePreciseTarget: Bool, completion: @escaping (Bool) -> Void) {
        jumpThenKeys(s, scripts: [keyCodeScript(36)], requirePreciseTarget: requirePreciseTarget, completion: completion)
    }

    /// 拒否 = Escape
    static func deny(_ s: AgentSession, requirePreciseTarget: Bool, completion: @escaping (Bool) -> Void) {
        jumpThenKeys(s, scripts: [keyCodeScript(53)], requirePreciseTarget: requirePreciseTarget, completion: completion)
    }

    /// 選択肢 n 番を選んで Return
    static func answer(_ s: AgentSession, option: Int, requirePreciseTarget: Bool, completion: @escaping (Bool) -> Void) {
        jumpThenKeys(
            s,
            scripts: [keystrokeScript("\(option)"), keyCodeScript(36)],
            requirePreciseTarget: requirePreciseTarget,
            completion: completion
        )
    }

    static func ensureAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - 内部処理

    /// 目的の画面を前面に出してからキーを送る。
    /// キーは「今フォーカスされているウィンドウ」に入るため、送信先を取り違えると
    /// 別のエージェントに承認が入ってしまう。そのため
    /// 1. ウィンドウ単位で特定できたか（できなければ requirePreciseTarget の場合は中止）
    /// 2. 送信直前に本当にそのアプリが前面か
    /// の2点を確かめてから送る。送れたかどうかを completion（メインスレッド）で返す。
    private static func jumpThenKeys(
        _ s: AgentSession,
        scripts: [String],
        requirePreciseTarget: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        _ = ensureAccessibility()
        workQueue.async {
            let precise = focus(s)
            guard precise || !requirePreciseTarget else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            workQueue.asyncAfter(deadline: .now() + 0.5) {
                guard frontIsTarget(s) else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                var delay = 0.0
                for script in scripts {
                    workQueue.asyncAfter(deadline: .now() + delay) { runOsascript(script) }
                    delay += 0.3
                }
                workQueue.asyncAfter(deadline: .now() + delay) {
                    DispatchQueue.main.async { completion(true) }
                }
            }
        }
    }

    /// キー送信の直前に、そのセッションのアプリが本当に前面かを確かめる
    private static func frontIsTarget(_ s: AgentSession) -> Bool {
        let host = s.hostBundleId
        guard !host.isEmpty else { return false }
        var front = ""
        DispatchQueue.main.sync {
            front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        }
        return front == host
    }

    private static func activateApp(for s: AgentSession) {
        let bundleId = s.bundleId.isEmpty ? guessBundleId(s.terminal) : s.bundleId
        guard !bundleId.isEmpty else { return }
        DispatchQueue.main.async {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    static func guessBundleId(_ terminal: String) -> String {
        switch terminal {
        case "iTerm": return "com.googlecode.iterm2"
        case "Terminal": return "com.apple.Terminal"
        case "Ghostty": return "com.mitchellh.ghostty"
        case "Warp": return "dev.warp.Warp-Stable"
        case "WezTerm": return "com.github.wez.wezterm"
        case "kitty": return "net.kovidgoyal.kitty"
        case "Cursor": return "com.todesktop.230313mzl4w4u92"
        case "VS Code": return "com.microsoft.VSCode"
        case "": return ""
        default: return "com.apple.Terminal"
        }
    }

    private static func runOsascript(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            let finished = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in finished.signal() }
            try p.run()
            if finished.wait(timeout: .now() + osascriptTimeout) == .timedOut {
                p.terminate()
                NSLog("AINotch: osascript がタイムアウトしたため終了しました")
            }
        } catch {
            NSLog("AINotch: osascript 失敗 \(error)")
        }
    }

    private static func itermJumpScript(uuid: String) -> String {
        let uuidLiteral = appleScriptLiteral(uuid)
        return """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with sess in sessions of t
                        if id of sess contains \(uuidLiteral) then
                            select w
                            select t
                            select sess
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func terminalJumpScript(tty: String) -> String {
        let ttyLiteral = appleScriptLiteral(tty)
        return """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(ttyLiteral) then
                        set selected of t to true
                        set frontmost of w to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    private static func keyCodeScript(_ code: Int) -> String {
        "tell application \"System Events\" to key code \(code)"
    }

    private static func keystrokeScript(_ keys: String) -> String {
        "tell application \"System Events\" to keystroke \(appleScriptLiteral(keys))"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
