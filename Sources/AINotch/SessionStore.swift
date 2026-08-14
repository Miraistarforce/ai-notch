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

/// 質問（AskUserQuestion）のツール名。許可要求と同じ PermissionRequest hook で
/// 飛んでくるので、これだけは「許可」ではなく「質問」として扱う。
private let questionToolName = "AskUserQuestion"

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
    /// この承認要求が PermissionRequest hook 由来である（＝hook応答で答えられる種類のもの）。
    /// hookControlled かつ awaitingHookDecision でない＝すでにhookを解放済みで、
    /// ノッチからは答えられない（画面のダイアログで答えてもらう）。
    var hookControlled = false
    /// 現在の承認プロンプトの一意ID（同一セッション内の並行承認要求を区別する）
    var promptId = ""

    /// ウィンドウ照合に使うプロジェクト名（cwdの末尾。なければタイトル）。
    /// VS Code / Cursor のウィンドウタイトルは末尾がワークスペース名なので、これで特定できる。
    var projectName: String {
        cwd.isEmpty ? title : (cwd as NSString).lastPathComponent
    }

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

    /// 点滅色。承認/質問待ち=青、完了=緑（直後3秒）、エラー=赤。nilなら点滅しない
    var blinkColor: NSColor? {
        guard !acknowledged else { return nil }
        switch state {
        case .waitingApproval: return .systemBlue
        case .waitingInput: return question != nil ? .systemBlue : nil
        case .done: return Date().timeIntervalSince(updatedAt) < 3 ? .systemGreen : nil
        case .error: return .systemRed
        default: return nil
        }
    }

    /// このセッションが動いているホストアプリのバンドルID（不明なら空）
    var hostBundleId: String {
        bundleId.isEmpty ? TerminalControl.guessBundleId(terminal) : bundleId
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
    private struct HookDecision {
        let sessionId: String
        let value: String
    }

    @Published var sessions: [AgentSession] = []
    /// ノッチでのフォロー休止中のフォルダ（グループキー = cwd、なければtitle）。
    /// 休止中はイベントを受け取っても表示・点滅・自動オープン・音の対象にしない。
    @Published var mutedFolders: Set<String> = []
    /// 状態変化のたびに呼ばれる（パネルの開閉判定用）
    var onChange: (() -> Void)?

    /// フォルダグループのキー（NotchViewのfolderGroupsと同じ規則）
    static func folderKey(_ s: AgentSession) -> String {
        s.cwd.isEmpty ? s.title : s.cwd
    }

    func isMuted(_ s: AgentSession) -> Bool {
        mutedFolders.contains(Self.folderKey(s))
    }

    /// 休止中でないセッション（点滅・カウント・自動オープン・Enter承認の対象）
    var activeSessions: [AgentSession] {
        sessions.filter { !isMuted($0) }
    }

    /// フォルダの休止⇔再開を切り替える（1秒長押しで呼ばれる）
    func toggleMutedFolder(_ key: String) {
        if mutedFolders.contains(key) {
            mutedFolders.remove(key)
        } else {
            mutedFolders.insert(key)
        }
        notifyChanged()
    }

    /// 実行中のままこの秒数イベントが来なければエラー扱いにする
    private let staleSeconds: TimeInterval = 600
    private var tickTimer: Timer?
    /// 承認待ちがある間だけ、ウィンドウの切り替えを見張るタイマー
    private var frontWatchTimer: Timer?
    private let probeQueue = DispatchQueue(label: "ainotch.frontwindow")
    /// ユーザーが今見ているアプリ／ウィンドウ（キャッシュ。決定の瞬間は取り直す）
    private var front = FrontContext()
    /// PermissionRequest hookへ渡す決定（決定キー → セッションIDと決定値）
    private var decisions: [String: HookDecision] = [:]

    init() {
        front = FrontWindow.probe()
        // 定期チェック：無応答検知＋点滅の期限切れでパネルを閉じる判定を更新
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkStale()
            self.notifyChanged()
        }
    }

    deinit {
        tickTimer?.invalidate()
        frontWatchTimer?.invalidate()
    }

    /// パネルを開いたままにすべき状態。
    /// 点滅中（承認待ち・質問・完了直後・エラー）のセッションのうち、
    /// ユーザーが今その画面を見ていないものが1つでもあれば true。
    /// → 全ての点滅が解除された時点でパネルは自動で閉じる。
    var needsAttention: Bool { !attentionSessions().isEmpty }

    /// 注意が必要なセッション数（外側クリックで一時的に閉じた後、新しい通知が来たら開き直す判定に使う）
    var attentionCount: Int { attentionSessions().count }

    private func attentionSessions() -> [AgentSession] {
        let counts = hostCounts()
        return activeSessions.filter {
            $0.blinkColor != nil && !Self.isOnScreen($0, front: front, siblings: counts[$0.hostBundleId] ?? 1)
        }
    }

    // MARK: - 「今どのセッションの画面を見ているか」の判定

    /// ホストアプリごとのセッション数（同じアプリで複数動いているかの判定用）
    private func hostCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for s in sessions where !s.hostBundleId.isEmpty {
            counts[s.hostBundleId, default: 0] += 1
        }
        return counts
    }

    /// このセッションと同じアプリで動いている他のセッションがあるか。
    /// ある場合、アプリを前面にするだけでは目的のウィンドウを特定できない。
    func hasSibling(_ s: AgentSession) -> Bool { siblings(of: s) > 1 }

    private func siblings(of s: AgentSession) -> Int {
        let host = s.hostBundleId
        guard !host.isEmpty else { return 1 }
        return sessions.filter { $0.id != s.id && $0.hostBundleId == host }.count + 1
    }

    /// このセッションの画面（ターミナル/エディタのウィンドウ）をユーザーが今見ているか。
    ///
    /// 同じアプリで複数のセッションが動いている場合、バンドルIDの一致だけでは
    /// 「別ウィンドウの Claude Code を見ている」ケースと区別できない。
    /// その場合はウィンドウタイトルにプロジェクト名が含まれるかで判定し、
    /// 判定できないときは false（見ていない扱い）にする。
    /// → 誤ってhookを解放して、承認が別ウィンドウのエージェントへ流れるのを防ぐ。
    static func isOnScreen(_ s: AgentSession, front: FrontContext, siblings: Int) -> Bool {
        let host = s.hostBundleId
        guard !host.isEmpty, host == front.bundleId else { return false }
        guard siblings > 1 else { return true }
        // アクセシビリティ未許可の環境ではウィンドウを区別できない。
        // ただしキー送信もできない＝誤送信は起き得ないので、従来どおりアプリ単位で判定し、
        // 通常のダイアログ（画面側）に任せる
        guard FrontWindow.isTrusted() else { return true }
        let name = s.projectName
        guard !name.isEmpty, !front.windowTitle.isEmpty else { return false }
        return front.windowTitle.contains(name)
    }

    func isOnScreen(_ s: AgentSession) -> Bool {
        Self.isOnScreen(s, front: front, siblings: siblings(of: s))
    }

    /// デバッグ表示用（GET /debug）
    var frontContext: FrontContext { front }

    /// Enterキーで承認してよいセッション。次の両方を満たすときだけ有効にする。
    /// - 承認待ちがちょうど1つ、かつhook応答で確実にそのセッションへ返せる
    ///   （複数あるとどれに返るか決められず、別のエージェントを承認してしまう）
    /// - ユーザーが今見ているアプリが別のエージェントの画面でない
    ///   （そちらへ打っているEnterを横取りしないため）
    var enterApprovalTarget: AgentSession? {
        let pending = activeSessions.filter { $0.state == .waitingApproval }
        guard pending.count == 1, let target = pending.first, target.awaitingHookDecision else { return nil }
        let frontHostsOther = sessions.contains {
            $0.id != target.id && !$0.hostBundleId.isEmpty && $0.hostBundleId == front.bundleId
        }
        return frontHostsOther ? nil : target
    }

    /// Clawdアニメーションの状態（優先度: エラー > 承認待ち > 完了の喜び > 作業中 > 散歩 > 待機）
    var clawdMode: ClawdMode {
        let active = activeSessions
        if active.contains(where: { $0.state == .error && !$0.acknowledged }) {
            return .alert(isError: true)
        }
        if active.contains(where: {
            ($0.state == .waitingApproval || ($0.state == .waitingInput && $0.question != nil)) && !$0.acknowledged
        }) {
            return .alert(isError: false)
        }
        if active.contains(where: { $0.state == .done && $0.blinkColor != nil }) {
            return .joy
        }
        if workingCount > 0 { return .work }
        return active.isEmpty ? .idle : .walk
    }

    /// アプリ切り替え時に呼ぶ。点滅中の完了/エラーのセッションの画面を開いたら
    /// 「確認済み」にして点滅を解除する（承認待ちは画面を離れたら再点滅させたいので解除しない）
    func frontmostChanged(_ app: NSRunningApplication?) {
        // ウィンドウタイトルは非同期で取り直すので、いったん空にして保守的な判定にする
        front = FrontContext(bundleId: app?.bundleIdentifier ?? "")
        applyFront()
        refreshFront(app)
    }

    /// 前面ウィンドウを取り直す（同じアプリの中でのウィンドウ切り替えも拾うため定期的に呼ぶ）
    private func refreshFront(_ app: NSRunningApplication? = nil) {
        probeQueue.async { [weak self] in
            let ctx = FrontWindow.probe(app)
            DispatchQueue.main.async {
                guard let self, ctx.bundleId != self.front.bundleId || ctx.windowTitle != self.front.windowTitle
                else { return }
                self.front = ctx
                self.applyFront()
            }
        }
    }

    /// 今見ている画面に応じて、点滅解除とhookの解放を行う
    private func applyFront() {
        let counts = hostCounts()
        var updated = sessions
        var sessionsChanged = false
        for i in updated.indices {
            let s = updated[i]
            guard Self.isOnScreen(s, front: front, siblings: counts[s.hostBundleId] ?? 1) else { continue }
            if !s.acknowledged, s.state == .done || s.state == .error {
                updated[i].acknowledged = true
                sessionsChanged = true
            }
            // 承認待ちのセッションの画面を開いたら、hookを解放して
            // 通常の承認ダイアログをその画面に出す（ユーザーが直接答えられるように）
            if s.state == .waitingApproval, s.awaitingHookDecision {
                decisions[decisionKey(s.id, s.promptId)] = HookDecision(sessionId: s.id, value: "defer")
                updated[i].awaitingHookDecision = false
                updated[i].statusText = "画面のダイアログで回答してください"
                sessionsChanged = true
            }
        }
        if sessionsChanged { sessions = updated }
        notifyChanged()
    }

    /// 承認待ちがある間だけ、1秒ごとに前面ウィンドウを見張る。
    /// （同じアプリ内でのウィンドウ切り替えはアプリ切り替え通知が飛ばないため）
    private func updateFrontWatch() {
        let needed = sessions.contains { $0.state == .waitingApproval && $0.awaitingHookDecision }
        if needed {
            guard frontWatchTimer == nil else { return }
            frontWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshFront()
            }
        } else {
            frontWatchTimer?.invalidate()
            frontWatchTimer = nil
        }
    }

    /// 状態が変わったことを通知する（見張りタイマーの要否もここで見直す）
    private func notifyChanged() {
        updateFrontWatch()
        onChange?()
    }

    // MARK: - 承認の決定（PermissionRequest hook連携）

    private func decisionKey(_ sid: String, _ promptId: String) -> String {
        promptId.isEmpty ? sid : "\(sid):\(promptId)"
    }

    /// ノッチのボタンから決定を登録する。hookがポーリングで受け取り、Claude Codeに直接返す。
    /// 決定は「セッションID:プロンプトID」で紐づくので、他のエージェントには絶対に届かない。
    func decide(_ id: String, decision: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else {
            decisions[id] = HookDecision(sessionId: id, value: decision)
            notifyChanged()
            return
        }
        var session = sessions[i]
        decisions[decisionKey(id, session.promptId)] = HookDecision(sessionId: id, value: decision)
        switch decision {
        case "allow":
            session.state = .working
            session.statusText = "許可しました — 実行中…"
        case "allow_always":
            session.state = .working
            session.statusText = "許可しました（今後は確認なし）"
        case "deny":
            session.state = .working
            session.statusText = "拒否しました"
        default:
            break
        }
        if decision != "defer" {
            session.permission = nil
            session.question = nil
            session.awaitingHookDecision = false
        }
        sessions[i] = session
        notifyChanged()
    }

    /// hookのポーリングに応答する。決定があれば取り出して返す（1回限り）。
    /// key は「セッションID」または「セッションID:プロンプトID」。
    func takeDecision(_ key: String) -> String? {
        guard let decision = decisions[key] else { return nil }
        decisions.removeValue(forKey: key)
        if let i = sessions.firstIndex(where: { $0.id == decision.sessionId }),
           sessions[i].awaitingHookDecision {
            var session = sessions[i]
            session.awaitingHookDecision = false
            sessions[i] = session
        }
        return decision.value
    }
    var workingCount: Int { activeSessions.lazy.filter { $0.state == .working }.count }
    var pendingCount: Int { activeSessions.lazy.filter { $0.state == .waitingApproval || $0.state == .waitingInput }.count }
    var doneCount: Int { activeSessions.lazy.filter { $0.state == .done }.count }
    var errorCount: Int { activeSessions.lazy.filter { $0.state == .error }.count }

    // MARK: - イベント処理

    func handle(_ dict: [String: Any]) {
        let hookEvent = str(dict["hook_event_name"])
        let ev = hookEvent.isEmpty ? str(dict["event"]) : hookEvent
        guard !ev.isEmpty else { return }
        let rawSessionId = str(dict["session_id"])
        let sid = rawSessionId.isEmpty ? "unknown" : rawSessionId

        var s = sessions.first(where: { $0.id == sid }) ?? newSession(id: sid, dict: dict)
        updateEnvironment(&s, dict: dict)
        let now = Date()
        // 質問は PreToolUse と PermissionRequest の2回飛んでくるので、
        // 「さっきまで質問待ちだったか」を見て音を鳴らし直さないようにする
        let wasWaitingQuestion = s.state == .waitingInput && s.question != nil
        s.updatedAt = now

        // Claude Code hooks経由のセッションは、開いているフォルダ名をタイトルにする
        if !hookEvent.isEmpty, !s.cwd.isEmpty {
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
            if tool == questionToolName {
                applyQuestion(&s, input: input, alreadyNotified: wasWaitingQuestion)
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
            // 質問（AskUserQuestion）にもこのイベントが飛ぶ（2026-08-14に実測）。
            // これは「許可」ではないので承認カードにしてはいけない。しかもhookを掴んだままだと
            // そのAIの画面に質問UIが出ないので、すぐdeferで解放して画面側に出させる。
            // ノッチは内容と「質問に答える」（＝その画面へ移動）だけを出す。
            if tool == questionToolName {
                let promptId = str(dict["prompt_id"])
                applyQuestion(&s, input: input, alreadyNotified: wasWaitingQuestion)
                decisions[decisionKey(sid, promptId)] = HookDecision(sessionId: sid, value: "defer")
                break
            }
            let detail = toolDetail(tool, input)
            s.state = .waitingApproval
            s.permission = detail
            s.lastTool = detail
            s.statusText = "許可待ち: \(detail.summary)"
            s.acknowledged = false
            s.hookControlled = true
            s.awaitingHookDecision = true
            s.promptId = str(dict["prompt_id"])
            decisions.removeValue(forKey: decisionKey(sid, s.promptId))
            // 「そのセッションの画面を見ているか」はウィンドウ単位で確かめる。
            // ここを取り違えると、hookを解放したうえでノッチのボタンがキー送信に
            // フォールバックし、前面にある別のエージェントへ承認が入ってしまう。
            front = FrontWindow.probe()
            if Self.isOnScreen(s, front: front, siblings: siblings(of: s)) || isMuted(s) {
                // 画面を見ている・休止中ならノッチは介入せず、すぐ通常のダイアログを出す
                decisions[decisionKey(sid, s.promptId)] = HookDecision(sessionId: sid, value: "defer")
                s.awaitingHookDecision = false
            } else {
                playSound("Ping")
            }
        case "PostToolUse":
            s.state = .working
            s.statusText = "考え中…"
            s.permission = nil
            // 質問に答え終わった直後もここに来る（回答済みなので質問カードは消す）
            s.question = nil
        case "Notification":
            let msg = str(dict["message"]).lowercased()
            let ntype = str(dict["notification_type"])
            if ntype == "permission_prompt" || msg.contains("permission") || msg.contains("許可") {
                s.state = .waitingApproval
                // hook由来ではないのでhook応答では返せない。ノッチのボタンはキー送信になる
                s.hookControlled = false
                s.awaitingHookDecision = false
                s.permission = s.lastTool ?? PermissionRequest(toolName: "", summary: str(dict["message"]), lines: [])
                s.statusText = "許可待ち: \(s.permission?.summary ?? "")"
                s.acknowledged = false
                if !isMuted(s) { playSound("Ping") }
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
            if !isMuted(s) { playSound("Glass") }
            scheduleAutoAcknowledge(sid)
        case "SessionEnd":
            removeSession(id: sid)
            notifyChanged()
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
            if !isMuted(s) { playSound("Glass") }
            scheduleAutoAcknowledge(sid)
        case "error":
            s.state = .error
            let st = str(dict["status"])
            s.statusText = st.isEmpty ? "エラーが発生しました" : st
            s.permission = nil
            s.question = nil
            s.acknowledged = false
            if !isMuted(s) { playSound("Basso") }
        case "remove":
            removeSession(id: sid)
            notifyChanged()
            return
        default:
            break
        }

        upsertAndMaintain(s, now: now)
        notifyChanged()
    }

    func clearFinished() {
        let remaining = sessions.filter { $0.state != .done && $0.state != .idle }
        guard remaining.count != sessions.count else { return }
        sessions = remaining
        notifyChanged()
    }

    /// キー送信中の表示（送信先が確定するまで承認カードは消さない）
    func markSending(_ id: String, text: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].statusText = text
        notifyChanged()
    }

    /// キー送信の結果を反映する。
    /// 失敗＝送信先のウィンドウを特定できなかったので、承認カードを残したまま
    /// 「画面で回答してください」と伝える（別のエージェントに送ってしまうより安全）。
    func markKeySendResult(_ id: String, success: Bool, text: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[i]
        session.statusText = text
        if success {
            session.state = .working
            session.permission = nil
            session.question = nil
        } else {
            session.acknowledged = false
        }
        sessions[i] = session
        notifyChanged()
    }

    /// 完了から4秒後に自動で了解済みにする（ボタンを押さなくても点滅・注意状態を解除）
    private func scheduleAutoAcknowledge(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self,
                  let i = self.sessions.firstIndex(where: { $0.id == id }),
                  self.sessions[i].state == .done,
                  !self.sessions[i].acknowledged else { return }
            self.sessions[i].acknowledged = true
            self.notifyChanged()
        }
    }

    /// 行クリックで確認済みにする（点滅・自動オープンを止める）
    func acknowledge(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), !sessions[i].acknowledged else { return }
        var session = sessions[i]
        session.acknowledged = true
        sessions[i] = session
        notifyChanged()
    }

    /// 実行中のまま長時間イベントが来ないセッションをエラー扱いにする
    private func checkStale() {
        let now = Date()
        var updated = sessions
        var changed = false
        for i in updated.indices where updated[i].state == .working {
            if now.timeIntervalSince(updated[i].updatedAt) > staleSeconds {
                updated[i].state = .error
                updated[i].statusText = "応答が停止しています（エラー/API制限の可能性）"
                updated[i].acknowledged = false
                changed = true
            }
        }
        if changed {
            sortSessions(&updated)
            sessions = updated
            playSound("Basso")
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
        let title = str(dict["title"])
        let agent = str(dict["agent"])
        let bundleId = str(dict["bundle_id"])
        return AgentSession(
            id: id,
            title: title.isEmpty ? defaultTitle(dict) : title,
            agent: agent.isEmpty ? "Claude" : agent,
            terminal: terminalName(str(dict["term_program"]), bundleId: bundleId),
            bundleId: bundleId,
            tty: str(dict["tty"]),
            itermUUID: itermUUID(str(dict["iterm_session_id"])),
            cwd: str(dict["cwd"])
        )
    }

    private func updateEnvironment(_ s: inout AgentSession, dict: [String: Any]) {
        let title = str(dict["title"])
        let agent = str(dict["agent"])
        let tty = str(dict["tty"])
        let bundleId = str(dict["bundle_id"])
        let cwd = str(dict["cwd"])
        let rawITermId = str(dict["iterm_session_id"])
        if !title.isEmpty { s.title = title }
        if !agent.isEmpty { s.agent = agent }
        if !tty.isEmpty { s.tty = tty }
        if !bundleId.isEmpty { s.bundleId = bundleId }
        // cwdは最初に見えたもの（＝開いているプロジェクトフォルダ）に固定する。
        // ツール実行中の cd でhookが報告するcwdが変わっても、グループ名・タイトルを引きずらせない
        if s.cwd.isEmpty, !cwd.isEmpty { s.cwd = cwd }
        if !rawITermId.isEmpty { s.itermUUID = itermUUID(rawITermId) }
        let term = terminalName(str(dict["term_program"]), bundleId: bundleId)
        if !term.isEmpty { s.terminal = term }
    }

    /// 1イベントにつき @Published の更新を1回にまとめ、SwiftUIの再描画を抑える。
    private func upsertAndMaintain(_ s: AgentSession, now: Date) {
        var updated = sessions
        if let i = updated.firstIndex(where: { $0.id == s.id }) {
            updated[i] = s
        } else {
            updated.append(s)
        }
        purge(&updated, now: now)
        sortSessions(&updated)
        sessions = updated
    }

    private func removeSession(id: String) {
        sessions = sessions.filter { $0.id != id }
        decisions = decisions.filter { $0.value.sessionId != id }
    }

    private func purge(_ sessions: inout [AgentSession], now: Date) {
        let cutoff = now.addingTimeInterval(-6 * 3600)
        sessions.removeAll { $0.updatedAt < cutoff }
        while sessions.count > 12 {
            if let i = sessions.firstIndex(where: { $0.state == .done || $0.state == .idle }) {
                sessions.remove(at: i)
            } else {
                sessions.removeFirst()
            }
        }
    }

    private func sortSessions(_ sessions: inout [AgentSession]) {
        let rank: (AgentSession) -> Int = { s in
            switch s.state {
            case .waitingApproval, .waitingInput, .error: return 0
            case .working: return 1
            case .idle: return 2
            case .done: return 3
            }
        }
        sessions.sort {
            let lhsRank = rank($0)
            let rhsRank = rank($1)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
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

    /// 「AIからの質問」をセッションに反映する（PreToolUse と PermissionRequest の両方から呼ばれる）。
    /// 許可要求と違い、ノッチからは答えない（＝hookで返さない・キーも送らない）。
    /// 答えるのはそのAIの画面なので、ノッチは内容と移動ボタンだけを出す。
    private func applyQuestion(_ s: inout AgentSession, input: [String: Any], alreadyNotified: Bool) {
        s.state = .waitingInput
        s.question = parseQuestion(input)
        s.permission = nil
        s.statusText = "質問に回答待ち"
        s.acknowledged = false
        s.hookControlled = false
        s.awaitingHookDecision = false
        // 同じ質問で2回鳴らさない（PreToolUse → PermissionRequest と続けて飛んでくるため）
        if !alreadyNotified, !isMuted(s) { playSound("Ping") }
    }

    private func parseQuestion(_ input: [String: Any]) -> PendingQuestion {
        if let questions = input["questions"] as? [[String: Any]], let q = questions.first {
            var text = str(q["question"])
            // 一度に複数問聞かれることがある。ノッチは1問目だけ出して、残りは件数で示す
            if questions.count > 1 { text += "（他 \(questions.count - 1) 問）" }
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
