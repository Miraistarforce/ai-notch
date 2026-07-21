import CryptoKit
import Foundation

/// 連携対象のAIツール1件分
struct AITool: Identifiable {
    let id: String            // claude / codex / gemini
    let name: String          // 表示名
    let detail: String        // 補足（どこで動くか）
    let configPath: String    // 書き込み先（表示用）
    var detected: Bool        // このMacにインストールされているか
    var enabled: Bool         // hookが登録済みか
}

enum HookSetupError: LocalizedError {
    case scriptsMissing
    case configBroken(String)

    var errorDescription: String? {
        switch self {
        case .scriptsMissing:
            return "hookスクリプトが見つかりません。アプリを .app バンドル（make run）で起動し直してください。"
        case .configBroken(let path):
            return "\(path) を読み取れませんでした（JSONが壊れている可能性）。"
        }
    }
}

/// 各AI CLIの設定ファイルへのhook登録・解除と、スクリプトの配置を担う。
/// どのMacでも動くよう、パスはすべてホームディレクトリから計算し、
/// hookスクリプトは .app 内から ~/Library/Application Support/AINotch/hooks/ へコピーして使う。
final class HookSetup {
    static let shared = HookSetup()

    private let fm = FileManager.default
    private var home: URL { fm.homeDirectoryForCurrentUser }

    /// hookスクリプトの配置先（設定ファイルにはこのパスを書き込む）
    var scriptsDir: URL {
        home.appendingPathComponent("Library/Application Support/AINotch/hooks")
    }
    var hookScript: URL { scriptsDir.appendingPathComponent("notch-hook.sh") }

    private var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    private var codexHooks: URL { home.appendingPathComponent(".codex/hooks.json") }
    private var geminiSettings: URL { home.appendingPathComponent(".gemini/settings.json") }

    /// このスクリプトを含むhook定義だけを自分のものとして扱う（追加・削除の目印）
    private let marker = "notch-hook.sh"

    // MARK: - スクリプトの配置

    /// .app 内の Resources/hooks を Application Support へコピーする（起動時に毎回同期）。
    /// 開発中（swift run 等でバンドルにhooksが無い場合）は既存の配置をそのまま使う。
    func syncBundledScripts() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("hooks"),
              fm.fileExists(atPath: bundled.path) else { return }
        do {
            try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: bundled.path) {
                let src = bundled.appendingPathComponent(name)
                let dst = scriptsDir.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            }
        } catch {
            NSLog("AINotch: hookスクリプトの同期に失敗 \(error)")
        }
    }

    // MARK: - 検出と状態

    func tools() -> [AITool] {
        [
            AITool(
                id: "claude",
                name: "Claude Code",
                detail: "ターミナル / Cursor / VS Code 内のClaude Code",
                configPath: "~/.claude/settings.json",
                detected: fm.fileExists(atPath: claudeSettings.deletingLastPathComponent().path),
                enabled: fileContainsMarker(claudeSettings)
            ),
            AITool(
                id: "codex",
                name: "Codex（ChatGPT）",
                detail: "Codex CLI / ChatGPTアプリのコーディングエージェント",
                configPath: "~/.codex/hooks.json",
                detected: fm.fileExists(atPath: home.appendingPathComponent(".codex").path)
                    || fm.fileExists(atPath: "/Applications/ChatGPT.app"),
                enabled: fileContainsMarker(codexHooks)
            ),
            AITool(
                id: "gemini",
                name: "Gemini CLI",
                detail: "Google Gemini CLI",
                configPath: "~/.gemini/settings.json",
                detected: geminiInstalled(),
                enabled: fileContainsMarker(geminiSettings)
            ),
        ]
    }

    private func geminiInstalled() -> Bool {
        let candidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            home.appendingPathComponent(".local/bin/gemini").path,
            home.appendingPathComponent(".npm-global/bin/gemini").path,
        ]
        return candidates.contains { fm.fileExists(atPath: $0) }
    }

    private func fileContainsMarker(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    // MARK: - オン/オフ

    func setEnabled(_ id: String, _ on: Bool) throws {
        if on, !fm.fileExists(atPath: hookScript.path) {
            throw HookSetupError.scriptsMissing
        }
        switch id {
        case "claude": try updateClaude(on: on)
        case "codex": try updateCodex(on: on)
        case "gemini": try updateGemini(on: on)
        default: break
        }
    }

    /// Claude Code: ~/.claude/settings.json（matcher形式、PermissionRequestは応答待ちのためtimeout 300）
    private func updateClaude(on: Bool) throws {
        var root = try loadJSON(claudeSettings)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        removeMarked(&hooks, nested: true)
        if on {
            let cmd = "\"\(hookScript.path)\""
            let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                          "PermissionRequest", "Notification", "Stop", "SessionEnd"]
            for ev in events {
                var matchers = hooks[ev] as? [[String: Any]] ?? []
                var def: [String: Any] = ["type": "command", "command": cmd]
                if ev == "PermissionRequest" { def["timeout"] = 300 }
                var entry: [String: Any] = ["hooks": [def]]
                if ev == "PreToolUse" || ev == "PostToolUse" { entry["matcher"] = "*" }
                matchers.append(entry)
                hooks[ev] = matchers
            }
        }
        root["hooks"] = hooks
        try saveJSON(root, to: claudeSettings)
    }

    /// Codex: ~/.codex/hooks.json（Claude互換形式）に登録し、config.toml に信頼情報を書く。
    /// Codexは未承認（untrusted）のhookを実行しないため、登録だけでは動かない。
    /// ユーザーが設定画面でオンにした操作を同意とみなし、hooks.state に trusted_hash を書き込む。
    /// config.toml は notify 等の既存設定に触れず、マーカーで囲んだ専用ブロックだけを追記・削除する。
    private func updateCodex(on: Bool) throws {
        var root = try loadJSON(codexHooks)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        removeMarked(&hooks, nested: true)
        var trustEntries: [(key: String, hash: String)] = []
        if on {
            let cmd = "\"\(hookScript.path)\" codex"
            // (イベント名, stateキー用ラベル, 正規化タイムアウト秒)
            let events: [(name: String, label: String, timeout: Int)] = [
                ("SessionStart", "session_start", 600),
                ("UserPromptSubmit", "user_prompt_submit", 600),
                ("PreToolUse", "pre_tool_use", 600),
                ("PostToolUse", "post_tool_use", 600),
                ("PermissionRequest", "permission_request", 300),
                ("Stop", "stop", 600),
            ]
            for ev in events {
                var matchers = hooks[ev.name] as? [[String: Any]] ?? []
                var def: [String: Any] = ["type": "command", "command": cmd]
                if ev.name == "PermissionRequest" { def["timeout"] = 300 }
                matchers.append(["hooks": [def]])
                hooks[ev.name] = matchers
                // stateキーは「<hooks.jsonのパス>:<ラベル>:<グループ番号>:<ハンドラ番号>」
                let key = "\(codexHooks.path):\(ev.label):\(matchers.count - 1):0"
                trustEntries.append((key, Self.codexTrustHash(label: ev.label, command: cmd, timeout: ev.timeout)))
            }
        }
        root["hooks"] = hooks
        try saveJSON(root, to: codexHooks)
        try writeCodexTrustBlock(trustEntries)
    }

    /// Codexの trusted_hash を再現する:
    /// 正規化したhook定義（event_name + hooks配列、timeout明示・async=false）を
    /// キー昇順の圧縮JSONにしてSHA-256（openai/codex の version_for_toml と同じ計算）。
    static func codexTrustHash(label: String, command: String, timeout: Int) -> String {
        var escaped = ""
        for scalar in command.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        let json = "{\"event_name\":\"\(label)\",\"hooks\":[{\"async\":false,\"command\":\"\(escaped)\",\"timeout\":\(timeout),\"type\":\"command\"}]}"
        let digest = SHA256.hash(data: Data(json.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private let trustBlockBegin = "# >>> AI Notch hooks trust >>>"
    private let trustBlockEnd = "# <<< AI Notch hooks trust <<<"

    /// config.toml の専用ブロックを入れ替える（entriesが空なら削除のみ）。
    private func writeCodexTrustBlock(_ entries: [(key: String, hash: String)]) throws {
        let configURL = home.appendingPathComponent(".codex/config.toml")
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        if let begin = text.range(of: trustBlockBegin), let end = text.range(of: trustBlockEnd),
           begin.lowerBound <= end.lowerBound {
            text.removeSubrange(begin.lowerBound..<end.upperBound)
        }
        while text.hasSuffix("\n") { text.removeLast() }

        if !entries.isEmpty {
            var block = trustBlockBegin + "\n"
            for entry in entries {
                block += "[hooks.state.\"\(entry.key)\"]\n"
                block += "trusted_hash = \"\(entry.hash)\"\n"
            }
            block += trustBlockEnd
            text = text.isEmpty ? block : text + "\n\n" + block
        }
        text += "\n"

        // バックアップしてから書き込み
        if fm.fileExists(atPath: configURL.path) {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMddHHmmss"
            try? fm.copyItem(atPath: configURL.path, toPath: configURL.path + ".bak-" + df.string(from: Date()))
        }
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Gemini CLI: ~/.gemini/settings.json（hook定義が直接並ぶフラット形式）
    private func updateGemini(on: Bool) throws {
        var root = try loadJSON(geminiSettings)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        removeMarked(&hooks, nested: false)
        if on {
            let cmd = "\"\(hookScript.path)\" gemini"
            let events = ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent",
                          "BeforeTool", "AfterTool", "Notification"]
            for ev in events {
                var defs = hooks[ev] as? [[String: Any]] ?? []
                defs.append(["type": "command", "command": cmd, "name": "ai-notch"])
                hooks[ev] = defs
            }
        }
        root["hooks"] = hooks
        try saveJSON(root, to: geminiSettings)
    }

    // MARK: - JSON操作

    private func loadJSON(_ url: URL) throws -> [String: Any] {
        guard fm.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw HookSetupError.configBroken(url.path)
        }
        return dict
    }

    private func saveJSON(_ dict: [String: Any], to url: URL) throws {
        // 既存ファイルはタイムスタンプ付きでバックアップ
        if fm.fileExists(atPath: url.path) {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMddHHmmss"
            let backup = url.path + ".bak-" + df.string(from: Date())
            try? fm.copyItem(atPath: url.path, toPath: backup)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// 自分のスクリプトを含むhook定義をすべて取り除く。
    /// nested=true はClaude/Codexのmatcher形式、falseはGeminiのフラット形式。
    private func removeMarked(_ hooks: inout [String: Any], nested: Bool) {
        for (ev, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            if nested {
                entries = entries.compactMap { entry in
                    var e = entry
                    guard let rawDefs = e["hooks"] as? [[String: Any]] else { return e }
                    let defs = rawDefs.filter {
                        !(($0["command"] as? String) ?? "").contains(marker)
                    }
                    if defs.isEmpty { return nil }
                    e["hooks"] = defs
                    return e
                }
            } else {
                entries = entries.filter {
                    !(($0["command"] as? String) ?? "").contains(marker)
                }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: ev)
            } else {
                hooks[ev] = entries
            }
        }
    }
}
