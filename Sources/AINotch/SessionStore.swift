import AppKit
import Foundation

enum SessionState: String {
    case idle
    case working
    case waitingApproval  // ツール実行の許可待ち
    case waitingInput     // 質問への回答待ち
    case done
}

struct PermissionRequest {
    var toolName: String
    var summary: String     // 例: "Edit src/auth/middleware.ts"
    var lines: [String]     // diffプレビュー等（-/+付き）
}

struct PendingQuestion {
    var text: String
    var options: [String]
}

struct AgentSession: Identifiable {
    let id: String
    var title: String
    var agent: String        // Claude / Codex / Gemini / ...
    var terminal: String     // iTerm / Terminal / Ghostty / ...
    var bundleId: String
    var tty: String
    var itermUUID: String
    var cwd: String
    var state: SessionState = .idle
    var statusText: String = ""
    var permission: PermissionRequest?
    var question: PendingQuestion?
    var lastTool: PermissionRequest?
    var startedAt = Date()
    var updatedAt = Date()

    var stateColor: NSColor {
        switch state {
        case .working: return .systemGreen
        case .waitingApproval: return .systemOrange
        case .waitingInput: return .systemCyan
        case .done: return .systemBlue
        case .idle: return .systemGray
        }
    }

    var elapsedText: String {
        let sec = Int(Date().timeIntervalSince(startedAt))
        if sec < 60 { return "\(sec)秒" }
        let min = sec / 60
        if min < 60 { return "\(min)分" }
        return "\(min / 60)時間\(min % 60)分"
    }
}

final class SessionStore: ObservableObject {
    @Published var sessions: [AgentSession] = []
    var onPendingChanged: (() -> Void)?

    var hasPending: Bool {
        sessions.contains { $0.state == .waitingApproval || ($0.state == .waitingInput && $0.question != nil) }
    }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var pendingCount: Int { sessions.filter { $0.state == .waitingApproval || $0.state == .waitingInput }.count }
    var doneCount: Int { sessions.filter { $0.state == .done }.count }

    // MARK: - イベント処理

    func handle(_ dict: [String: Any]) {
        let ev = str(dict["hook_event_name"]).isEmpty ? str(dict["event"]) : str(dict["hook_event_name"])
        guard !ev.isEmpty else { return }
        let sid = str(dict["session_id"]).isEmpty ? "unknown" : str(dict["session_id"])
        let hadPending = hasPending

        var s = sessions.first(where: { $0.id == sid }) ?? newSession(id: sid, dict: dict)
        updateEnvironment(&s, dict: dict)
        s.updatedAt = Date()

        switch ev {
        case "SessionStart":
            s.state = .idle
            s.statusText = "起動しました"
        case "UserPromptSubmit":
            let prompt = str(dict["prompt"])
            if !prompt.isEmpty, s.title == defaultTitle(dict) || s.title.isEmpty {
                s.title = truncate(prompt.replacingOccurrences(of: "\n", with: " "), 32)
            }
            s.state = .working
            s.statusText = "考え中…"
            s.permission = nil
            s.question = nil
        case "PreToolUse":
            let tool = str(dict["tool_name"])
            let input = dict["tool_input"] as? [String: Any] ?? [:]
            if tool == "AskUserQuestion" {
                s.state = .waitingInput
                s.question = parseQuestion(input)
                s.statusText = "質問に回答待ち"
                playSound("Ping")
            } else {
                s.state = .working
                s.lastTool = toolDetail(tool, input)
                s.statusText = toolStatus(tool, input)
            }
        case "PostToolUse":
            s.state = .working
            s.statusText = "考え中…"
            s.permission = nil
        case "Notification":
            let msg = str(dict["message"]).lowercased()
            if msg.contains("permission") || msg.contains("許可") {
                s.state = .waitingApproval
                s.permission = s.lastTool ?? PermissionRequest(toolName: "", summary: str(dict["message"]), lines: [])
                s.statusText = "許可待ち: \(s.permission?.summary ?? "")"
                playSound("Ping")
            } else if msg.contains("waiting") || msg.contains("入力") {
                s.state = .waitingInput
                s.statusText = "入力待ち"
            }
        case "Stop":
            s.state = .done
            s.statusText = "完了 — クリックで移動"
            s.permission = nil
            s.question = nil
            playSound("Glass")
        case "SessionEnd":
            sessions.removeAll { $0.id == sid }
            notifyPendingIfChanged(hadPending)
            return
        // 汎用イベント（notch-run / notch-report / codex-notify 用）
        case "start":
            s.state = .working
            let st = str(dict["status"])
            s.statusText = st.isEmpty ? "実行中…" : st
        case "status":
            s.state = .working
            s.statusText = str(dict["status"])
        case "done":
            s.state = .done
            let st = str(dict["status"])
            s.statusText = st.isEmpty ? "完了 — クリックで移動" : st
            playSound("Glass")
        case "remove":
            sessions.removeAll { $0.id == sid }
            notifyPendingIfChanged(hadPending)
            return
        default:
            break
        }

        upsert(s)
        purge()
        sortSessions()
        notifyPendingIfChanged(hadPending)
    }

    func clearFinished() {
        sessions.removeAll { $0.state == .done || $0.state == .idle }
    }

    /// 操作送信後の楽観的更新（キー送信がターミナル側で処理される想定）
    func markDecisionSent(_ id: String, text: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].state = .working
        sessions[i].statusText = text
        sessions[i].permission = nil
        sessions[i].question = nil
        onPendingChanged?()
    }

    func sessionsJSON() -> Data {
        let arr: [[String: Any]] = sessions.map { s in
            [
                "id": s.id, "title": s.title, "agent": s.agent, "terminal": s.terminal,
                "state": s.state.rawValue, "status": s.statusText, "tty": s.tty,
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted])) ?? Data("[]".utf8)
    }

    // MARK: - 内部処理

    private func notifyPendingIfChanged(_ hadPending: Bool) {
        if hadPending != hasPending || hasPending { onPendingChanged?() }
    }

    private func newSession(id: String, dict: [String: Any]) -> AgentSession {
        AgentSession(
            id: id,
            title: str(dict["title"]).isEmpty ? defaultTitle(dict) : str(dict["title"]),
            agent: str(dict["agent"]).isEmpty ? "Claude" : str(dict["agent"]),
            terminal: terminalName(str(dict["term_program"]), bundleId: str(dict["bundle_id"])),
            bundleId: str(dict["bundle_id"]),
            tty: str(dict["tty"]),
            itermUUID: itermUUID(str(dict["iterm_session_id"])),
            cwd: str(dict["cwd"])
        )
    }

    private func updateEnvironment(_ s: inout AgentSession, dict: [String: Any]) {
        if !str(dict["title"]).isEmpty { s.title = str(dict["title"]) }
        if !str(dict["agent"]).isEmpty { s.agent = str(dict["agent"]) }
        if !str(dict["tty"]).isEmpty { s.tty = str(dict["tty"]) }
        if !str(dict["bundle_id"]).isEmpty { s.bundleId = str(dict["bundle_id"]) }
        if !str(dict["cwd"]).isEmpty { s.cwd = str(dict["cwd"]) }
        if !str(dict["iterm_session_id"]).isEmpty { s.itermUUID = itermUUID(str(dict["iterm_session_id"])) }
        let term = terminalName(str(dict["term_program"]), bundleId: str(dict["bundle_id"]))
        if !term.isEmpty { s.terminal = term }
    }

    private func upsert(_ s: AgentSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[i] = s
        } else {
            sessions.append(s)
        }
    }

    private func purge() {
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        sessions.removeAll { $0.updatedAt < cutoff }
        while sessions.count > 12 {
            if let i = sessions.firstIndex(where: { $0.state == .done || $0.state == .idle }) {
                sessions.remove(at: i)
            } else {
                sessions.removeFirst()
            }
        }
    }

    private func sortSessions() {
        let rank: (AgentSession) -> Int = { s in
            switch s.state {
            case .waitingApproval, .waitingInput: return 0
            case .working: return 1
            case .idle: return 2
            case .done: return 3
            }
        }
        sessions.sort {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func defaultTitle(_ dict: [String: Any]) -> String {
        let cwd = str(dict["cwd"])
        if !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return "エージェント"
    }

    // MARK: - 日本語ステータス

    private func toolStatus(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let f = basename(str(input["file_path"]))
            return f.isEmpty ? "ファイルを編集中" : "\(f) を編集中"
        case "Read":
            let f = basename(str(input["file_path"]))
            return f.isEmpty ? "ファイルを読み込み中" : "\(f) を読み込み中"
        case "Bash":
            let c = truncate(str(input["command"]).replacingOccurrences(of: "\n", with: " "), 38)
            return c.isEmpty ? "コマンドを実行中" : "実行中: \(c)"
        case "Grep", "Glob":
            return "コードを検索中"
        case "WebSearch", "WebFetch":
            return "Webで調査中"
        case "Task", "Agent":
            return "サブエージェントを実行中"
        case "TodoWrite":
            return "タスクリストを更新中"
        case "ExitPlanMode", "EnterPlanMode":
            return "計画を作成中"
        default:
            return "\(tool) を実行中"
        }
    }

    private func toolDetail(_ tool: String, _ input: [String: Any]) -> PermissionRequest {
        var lines: [String] = []
        var summary = tool
        switch tool {
        case "Bash":
            let c = str(input["command"])
            summary = "Bash: \(truncate(c.replacingOccurrences(of: "\n", with: " "), 44))"
            lines = c.split(separator: "\n").prefix(4).map { "$ \($0)" }
        case "Edit", "MultiEdit":
            let f = shortPath(str(input["file_path"]))
            summary = "\(tool) \(f)"
            let old = str(input["old_string"]).split(separator: "\n").prefix(3).map { "- \($0)" }
            let new = str(input["new_string"]).split(separator: "\n").prefix(3).map { "+ \($0)" }
            lines = Array(old) + Array(new)
        case "Write":
            let f = shortPath(str(input["file_path"]))
            summary = "Write \(f)"
            lines = str(input["content"]).split(separator: "\n").prefix(4).map { "+ \($0)" }
        case "WebFetch":
            summary = "WebFetch \(truncate(str(input["url"]), 44))"
        default:
            summary = tool
        }
        return PermissionRequest(toolName: tool, summary: summary, lines: lines.map { truncate($0, 64) })
    }

    private func parseQuestion(_ input: [String: Any]) -> PendingQuestion {
        if let questions = input["questions"] as? [[String: Any]], let q = questions.first {
            let text = str(q["question"])
            let options = (q["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
            return PendingQuestion(text: text, options: options)
        }
        return PendingQuestion(text: "エージェントからの質問", options: [])
    }

    // MARK: - ヘルパー

    private func str(_ v: Any?) -> String { v as? String ?? "" }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    private func basename(_ path: String) -> String {
        path.isEmpty ? "" : (path as NSString).lastPathComponent
    }

    private func shortPath(_ path: String) -> String {
        let comps = (path as NSString).pathComponents
        if comps.count <= 3 { return path }
        return comps.suffix(3).joined(separator: "/")
    }

    private func itermUUID(_ raw: String) -> String {
        // ITERM_SESSION_ID は "w0t2p0:UUID" 形式
        if let colon = raw.firstIndex(of: ":") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw
    }

    private func playSound(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func terminalName(_ termProgram: String, bundleId: String) -> String {
        switch termProgram {
        case "iTerm.app": return "iTerm"
        case "Apple_Terminal": return "Terminal"
        case "ghostty": return "Ghostty"
        case "WarpTerminal": return "Warp"
        case "WezTerm": return "WezTerm"
        case "kitty": return "kitty"
        case "vscode":
            if bundleId.contains("todesktop") || bundleId.lowercased().contains("cursor") { return "Cursor" }
            return "VS Code"
        case "": return ""
        default: return termProgram
        }
    }
}
