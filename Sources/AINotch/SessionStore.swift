import AppKit
import Foundation

enum SessionState: String {
    case idle
    case working
    case waitingApproval  // ツール実行の許可待ち
    case waitingInput     // 質問への回答待ち
    case done
    case error            // エラー・API制限などで停止
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
    /// ユーザーが行をクリックして確認済み（点滅・自動オープンを止める）
    var acknowledged = false
    /// PermissionRequest hookがノッチの決定を待っている（trueなら承認ボタンはhook応答で機能する）
    var awaitingHookDecision = false
    /// 現在の承認プロンプトの一意ID（同一セッション内の並行承認要求を区別する）
    var promptId = ""

    /// 表示用エージェント名。Cursor / VS Code 内で動いている場合はホストを併記する
    /// （例: claude-cursor, claude-vscode）
    var agentLabel: String {
        switch terminal {
        case "Cursor": return "\(agent.lowercased())-cursor"
        case "VS Code": return "\(agent.lowercased())-vscode"
        default: return agent
        }
    }

    var stateColor: NSColor {
        switch state {
        case .working: return .systemTeal
        case .waitingApproval: return .systemBlue
        case .waitingInput: return .systemBlue
        case .done: return .systemGreen
        case .error: return .systemRed
        case .idle: return .systemGray
        }
    }

    /// 点滅色。承認/質問待ち=青、完了=緑（直後60秒）、エラー=赤。nilなら点滅しない
    var blinkColor: NSColor? {
        guard !acknowledged else { return nil }
        switch state {
        case .waitingApproval: return .systemBlue
        case .waitingInput: return question != nil ? .systemBlue : nil
        case .done: return Date().timeIntervalSince(updatedAt) < 60 ? .systemGreen : nil
        case .error: return .systemRed
        default: return nil
        }
    }

    /// このセッションが動いているホストアプリのバンドルID（不明なら空）
    var hostBundleId: String {
        bundleId.isEmpty ? TerminalControl.guessBundleId(terminal) : bundleId
    }

    /// このセッションの画面（ターミナル/エディタ）をユーザーが今見ているか
    var isOnScreen: Bool {
        let host = hostBundleId
        guard !host.isEmpty else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host
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
    /// 状態変化のたびに呼ばれる（パネルの開閉判定用）
    var onChange: (() -> Void)?

    /// 実行中のままこの秒数イベントが来なければエラー扱いにする
    private let staleSeconds: TimeInterval = 600
    private var tickTimer: Timer?
    /// PermissionRequest hookへ渡す決定（セッションID → allow/allow_always/deny/defer）
    private var decisions: [String: String] = [:]

    init() {
        // 定期チェック：無応答検知＋点滅の期限切れでパネルを閉じる判定を更新
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkStale()
            self?.onChange?()
        }
    }

    /// パネルを開いたままにすべき状態。
    /// 点滅中（承認待ち・質問・完了直後・エラー）のセッションのうち、
    /// ユーザーが今その画面を見ていないものが1つでもあれば true。
    /// → 全ての点滅が解除された時点でパネルは自動で閉じる。
    var needsAttention: Bool {
        sessions.contains { $0.blinkColor != nil && !$0.isOnScreen }
    }

    /// 注意が必要なセッション数（外側クリックで一時的に閉じた後、新しい通知が来たら開き直す判定に使う）
    var attentionCount: Int {
        sessions.filter { $0.blinkColor != nil && !$0.isOnScreen }.count
    }

    /// アプリ切り替え時に呼ぶ。点滅中の完了/エラーのセッションの画面を開いたら
    /// 「確認済み」にして点滅を解除する（承認待ちは画面を離れたら再点滅させたいので解除しない）
    func frontmostChanged(_ bundleId: String?) {
        guard let bid = bundleId, !bid.isEmpty else {
            onChange?()
            return
        }
        for i in sessions.indices {
            let s = sessions[i]
            if s.hostBundleId == bid, !s.acknowledged, s.state == .done || s.state == .error {
                sessions[i].acknowledged = true
            }
            // 承認待ちのセッションの画面を開いたら、hookを解放して
            // 通常の承認ダイアログをその画面に出す（ユーザーが直接答えられるように）
            if s.hostBundleId == bid, s.state == .waitingApproval, s.awaitingHookDecision {
                decisions[decisionKey(s.id, s.promptId)] = "defer"
                sessions[i].awaitingHookDecision = false
                sessions[i].statusText = "画面のダイアログで回答してください"
            }
        }
        onChange?()
    }

    // MARK: - 承認の決定（PermissionRequest hook連携）

    private func decisionKey(_ sid: String, _ promptId: String) -> String {
        promptId.isEmpty ? sid : "\(sid):\(promptId)"
    }

    /// ノッチのボタンから決定を登録する。hookがポーリングで受け取り、Claude Codeに直接返す。
    func decide(_ id: String, decision: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else {
            decisions[id] = decision
            onChange?()
            return
        }
        decisions[decisionKey(id, sessions[i].promptId)] = decision
        switch decision {
        case "allow":
            sessions[i].state = .working
            sessions[i].statusText = "許可しました — 実行中…"
        case "allow_always":
            sessions[i].state = .working
            sessions[i].statusText = "許可しました（今後は確認なし）"
        case "deny":
            sessions[i].state = .working
            sessions[i].statusText = "拒否しました"
        default:
            break
        }
        if decision != "defer" {
            sessions[i].permission = nil
            sessions[i].question = nil
        }
        onChange?()
    }

    /// hookのポーリングに応答する。決定があれば取り出して返す（1回限り）。
    /// key は「セッションID」または「セッションID:プロンプトID」。
    func takeDecision(_ key: String) -> String? {
        guard let d = decisions[key] else { return nil }
        decisions.removeValue(forKey: key)
        let sid = String(key.split(separator: ":", maxSplits: 1).first ?? "")
        if let i = sessions.firstIndex(where: { $0.id == sid || $0.id == key }) {
            sessions[i].awaitingHookDecision = false
        }
        return d
    }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var pendingCount: Int { sessions.filter { $0.state == .waitingApproval || $0.state == .waitingInput }.count }
    var doneCount: Int { sessions.filter { $0.state == .done }.count }
    var errorCount: Int { sessions.filter { $0.state == .error }.count }

    // MARK: - イベント処理

    func handle(_ dict: [String: Any]) {
        let ev = str(dict["hook_event_name"]).isEmpty ? str(dict["event"]) : str(dict["hook_event_name"])
        guard !ev.isEmpty else { return }
        let sid = str(dict["session_id"]).isEmpty ? "unknown" : str(dict["session_id"])

        var s = sessions.first(where: { $0.id == sid }) ?? newSession(id: sid, dict: dict)
        updateEnvironment(&s, dict: dict)
        s.updatedAt = Date()

        // Claude Code hooks経由のセッションは、開いているフォルダ名をタイトルにする
        if !str(dict["hook_event_name"]).isEmpty, !s.cwd.isEmpty {
            s.title = (s.cwd as NSString).lastPathComponent
        }

        switch ev {
        case "SessionStart":
            s.state = .idle
            s.statusText = "起動しました"
        case "UserPromptSubmit":
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
                s.acknowledged = false
                playSound("Ping")
            } else {
                s.state = .working
                s.lastTool = toolDetail(tool, input)
                s.statusText = toolStatus(tool, input)
            }
        case "PermissionRequest":
            // 許可ダイアログ表示の直前に発火する専用イベント。
            // hookはノッチの決定を待つので、ここでの承認ボタンは本物の許可/拒否として機能する。
            let tool = str(dict["tool_name"])
            let input = dict["tool_input"] as? [String: Any] ?? [:]
            let detail = toolDetail(tool, input)
            s.state = .waitingApproval
            s.permission = detail
            s.lastTool = detail
            s.statusText = "許可待ち: \(detail.summary)"
            s.acknowledged = false
            s.awaitingHookDecision = true
            s.promptId = str(dict["prompt_id"])
            decisions.removeValue(forKey: decisionKey(sid, s.promptId))
            if s.isOnScreen {
                // 画面を見ているならノッチは介入せず、すぐ通常のダイアログを出す
                decisions[decisionKey(sid, s.promptId)] = "defer"
                s.awaitingHookDecision = false
            } else {
                playSound("Ping")
            }
        case "PostToolUse":
            s.state = .working
            s.statusText = "考え中…"
            s.permission = nil
        case "Notification":
            let msg = str(dict["message"]).lowercased()
            let ntype = str(dict["notification_type"])
            if ntype == "permission_prompt" || msg.contains("permission") || msg.contains("許可") {
                s.state = .waitingApproval
                s.permission = s.lastTool ?? PermissionRequest(toolName: "", summary: str(dict["message"]), lines: [])
                s.statusText = "許可待ち: \(s.permission?.summary ?? "")"
                s.acknowledged = false
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
            s.acknowledged = false
            playSound("Glass")
        case "SessionEnd":
            sessions.removeAll { $0.id == sid }
            onChange?()
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
            s.acknowledged = false
            playSound("Glass")
        case "error":
            s.state = .error
            let st = str(dict["status"])
            s.statusText = st.isEmpty ? "エラーが発生しました" : st
            s.permission = nil
            s.question = nil
            s.acknowledged = false
            playSound("Basso")
        case "remove":
            sessions.removeAll { $0.id == sid }
            onChange?()
            return
        default:
            break
        }

        upsert(s)
        purge()
        sortSessions()
        onChange?()
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
        onChange?()
    }

    /// 行クリックで確認済みにする（点滅・自動オープンを止める）
    func acknowledge(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].acknowledged = true
        onChange?()
    }

    /// 実行中のまま長時間イベントが来ないセッションをエラー扱いにする
    private func checkStale() {
        var changed = false
        for i in sessions.indices where sessions[i].state == .working {
            if Date().timeIntervalSince(sessions[i].updatedAt) > staleSeconds {
                sessions[i].state = .error
                sessions[i].statusText = "応答が停止しています（エラー/API制限の可能性）"
                sessions[i].acknowledged = false
                changed = true
            }
        }
        if changed {
            playSound("Basso")
            sortSessions()
            onChange?()
        }
    }

    func sessionsJSON() -> Data {
        let arr: [[String: Any]] = sessions.map { s in
            [
                "id": s.id, "title": s.title, "agent": s.agentLabel, "terminal": s.terminal,
                "state": s.state.rawValue, "status": s.statusText, "tty": s.tty,
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted])) ?? Data("[]".utf8)
    }

    // MARK: - 内部処理

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
            case .waitingApproval, .waitingInput, .error: return 0
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
            lines = c.split(separator: "\n").prefix(20).map { "$ \($0)" }
        case "Edit", "MultiEdit":
            let f = shortPath(str(input["file_path"]))
            summary = "\(tool) \(f)"
            let old = str(input["old_string"]).split(separator: "\n").prefix(10).map { "- \($0)" }
            let new = str(input["new_string"]).split(separator: "\n").prefix(10).map { "+ \($0)" }
            lines = Array(old) + Array(new)
        case "Write":
            let f = shortPath(str(input["file_path"]))
            summary = "Write \(f)"
            lines = str(input["content"]).split(separator: "\n").prefix(14).map { "+ \($0)" }
        case "WebFetch":
            summary = "WebFetch \(truncate(str(input["url"]), 44))"
            lines = [str(input["url"])]
        default:
            summary = tool
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                lines = text.split(separator: "\n").prefix(12).map(String.init)
            }
        }
        return PermissionRequest(toolName: tool, summary: summary, lines: lines.map { truncate($0, 160) })
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
            if isCursor(bundleId) { return "Cursor" }
            return "VS Code"
        case "":
            // TERM_PROGRAMが無い環境（エディタ拡張内など）はバンドルIDから推測
            return terminalFromBundleId(bundleId)
        default: return termProgram
        }
    }

    private func isCursor(_ bundleId: String) -> Bool {
        bundleId.contains("todesktop") || bundleId.lowercased().contains("cursor")
    }

    private func terminalFromBundleId(_ bundleId: String) -> String {
        let b = bundleId.lowercased()
        if b.isEmpty { return "" }
        if isCursor(bundleId) { return "Cursor" }
        if b.contains("com.microsoft.vscode") { return "VS Code" }
        if b.contains("iterm") { return "iTerm" }
        if b.contains("com.apple.terminal") { return "Terminal" }
        if b.contains("ghostty") { return "Ghostty" }
        if b.contains("warp") { return "Warp" }
        if b.contains("wezterm") { return "WezTerm" }
        if b.contains("kitty") { return "kitty" }
        return ""
    }
}
