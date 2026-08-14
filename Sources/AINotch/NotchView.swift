import SwiftUI

struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    let actions: NotchActions

    var body: some View {
        ZStack(alignment: .top) {
            if ui.expanded {
                ExpandedPanel(store: store, ui: ui, actions: actions)
                    .transition(.scale(scale: 0.1, anchor: .top).combined(with: .opacity))
            } else {
                CollapsedBar(store: store, ui: ui)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // ホバーは「枠のどこかにカーソルがある」ことだけを枠全体で受け取り、
        // 実際に描かれている範囲にいるかは NotchWindowController.hoverChanged が
        // 座標で判定する。中身側に .onHover を付けると展開アニメーションの
        // 拡大縮小でホバーが外れ、乗せているのに閉じる／開閉がばたつく。
        // 位置が要るので onHover ではなく onContinuousHover を使う
        // （移動のたびに発火するので、余白から中身へ入った瞬間を拾える）。
        .onContinuousHover { phase in
            switch phase {
            case .active: actions.hover(true)
            case .ended: actions.hover(false)
            @unknown default: actions.hover(false)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: ui.expanded)
    }
}

// MARK: - フォルダグループ

struct FolderGroup: Identifiable {
    let id: String
    let name: String
    let color: Color
    let sessions: [AgentSession]
}

/// 同じフォルダ（cwd）で動くセッションをまとめる。表示順は保持。
func folderGroups(_ sessions: [AgentSession]) -> [FolderGroup] {
    var order: [String] = []
    var map: [String: [AgentSession]] = [:]
    for s in sessions {
        let key = s.cwd.isEmpty ? s.title : s.cwd
        if map[key] == nil { order.append(key) }
        map[key, default: []].append(s)
    }
    return order.map { key in
        let list = map[key] ?? []
        return FolderGroup(
            id: key,
            name: list.first?.title ?? key,
            color: groupColor(key),
            sessions: list
        )
    }
}

/// フォルダごとの識別色（状態色の緑/青/赤とかぶらない系統）
private let groupPalette: [Color] = [.purple, .yellow, .pink, .mint, .indigo, .orange, .brown]

func groupColor(_ key: String) -> Color {
    let sum = key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return groupPalette[sum % groupPalette.count]
}

// MARK: - 折りたたみ状態（ノッチ左右にインジケーター）

struct CollapsedBar: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.4)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 1.4) % 2 == 0
            HStack(spacing: 0) {
                // 左側：ノッチの中を歩き回るClawd（状態に応じてアニメーション変化）
                ZStack {
                    ClawdWalker(
                        range: (NotchWindowController.sideWidth - 44) / 2,
                        mode: store.clawdMode
                    )
                }
                .frame(width: NotchWindowController.sideWidth, height: ui.barHeight, alignment: .bottom)

                Spacer(minLength: ui.notchWidth)

                // 右側：状態ドットのみ（メニューバーを隠す幅を抑えるためテキストは出さない。
                // 件数と内訳は展開パネル側で見る）
                HStack(spacing: 4) {
                    if store.activeSessions.isEmpty {
                        Circle().fill(Color.gray.opacity(0.6)).frame(width: 6, height: 6)
                    } else {
                        ForEach(store.activeSessions.prefix(4)) { s in
                            let blinkColor = s.blinkColor
                            Circle()
                                .fill(Color(nsColor: blinkColor ?? s.stateColor))
                                .frame(width: 6, height: 6)
                                .opacity(blinkColor != nil && !phase ? 0.25 : 1.0)
                        }
                        // 4件を超える分は数で示す（黙って隠さない）
                        let hidden = store.activeSessions.count - 4
                        if hidden > 0 {
                            Text("+\(hidden)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                .frame(width: NotchWindowController.sideWidth)
            }
            // ウィンドウが展開サイズのままでも、閉じたバーは常に固定幅で中央に描画する
            // （開閉の瞬間にバーが横に伸びて見えるのを防ぐ）
            .frame(
                width: ui.notchWidth + 2 * NotchWindowController.sideWidth,
                height: ui.barHeight
            )
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 0
                )
                .fill(Color.black)
            )
        }
    }
}

// MARK: - 展開パネル

struct ExpandedPanel: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    let actions: NotchActions

    /// 一度に出す最大セッション数。ScrollViewを使わない代わりに、
    /// ウィンドウ枠（NotchWindowController.expandedHeight）に収まる数で頭打ちにする。
    /// セッションは対応が必要なものが先に来るよう並んでいるので、あふれるのは優先度の低い行。
    static let maxVisibleSessions = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, ui.barHeight > 30 ? ui.barHeight - 6 : 12)
                .padding(.bottom, 10)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            if store.sessions.isEmpty {
                emptyState
            } else {
                TimelineView(.periodic(from: .now, by: 1.4)) { ctx in
                    let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 1.4) % 2 == 0
                    // Enterで承認できるのは対象が一意に決まるときだけ。その行にだけ「Enter」と出す
                    let enterTargetId = store.enterApprovalTarget?.id
                    // ここにScrollViewを置いてはいけない。SwiftUIのScrollViewは
                    // 「与えられた高さいっぱいに広がる」ビューなので、下の fixedSize
                    // （＝中身の理想の高さを教えて）と組み合わせると、ウィンドウの
                    // レイアウト中にScrollViewがリサイズされ、その通知でSwiftUIが
                    // レイアウト中のウィンドウへ再度レイアウトを要求し、AppKitが例外を
                    // 投げてプロセスごと落ちる（2026-08-09に実際に発生）。
                    // 表示件数と差分行数を絞って、スクロール自体を要らなくしてある。
                    let visible = store.sessions.prefix(Self.maxVisibleSessions)
                    let hiddenCount = store.sessions.count - visible.count
                    // 承認・質問の詳細カードは一度に1件だけ広げる。全部広げると
                    // パネルが画面を覆ってしまい、枠の上限で下が切れる。
                    let detailId = visible.first {
                        $0.state == .waitingApproval || $0.state == .waitingInput
                    }?.id
                    VStack(spacing: 6) {
                        ForEach(folderGroups(Array(visible))) { group in
                            // 1秒長押しでフォルダ単位の休止⇔再開を切り替え
                            if store.mutedFolders.contains(group.id) {
                                MutedFolderTab(group: group) {
                                    store.toggleMutedFolder(group.id)
                                }
                            } else if group.sessions.count > 1 {
                                GroupCard(
                                    group: group,
                                    actions: actions,
                                    blinkPhase: phase,
                                    enterTargetId: enterTargetId,
                                    detailId: detailId
                                )
                                .onLongPressGesture(minimumDuration: 1.0) {
                                    store.toggleMutedFolder(group.id)
                                }
                            } else if let s = group.sessions.first {
                                SessionRow(
                                    session: s,
                                    actions: actions,
                                    inGroup: false,
                                    blinkPhase: phase,
                                    enterTargetId: enterTargetId,
                                    showDetail: s.id == detailId
                                )
                                .onLongPressGesture(minimumDuration: 1.0) {
                                    store.toggleMutedFolder(group.id)
                                }
                            }
                        }
                        // 入りきらない分は黙って隠さず件数で示す（折りたたみバーと同じ方針）
                        if hiddenCount > 0 {
                            Text("他 \(hiddenCount) 件（対応が必要なものから順に表示しています）")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }

            Spacer(minLength: 10)
        }
        .frame(width: NotchWindowController.expandedWidth)
        // 枠で頭打ちにする前の高さ。ここが maxPanelHeight を超えていたら中身が切れている
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { ui.naturalContentHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in ui.naturalContentHeight = h }
            }
        )
        .frame(maxHeight: ui.maxPanelHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                topTrailingRadius: 0
            )
            .fill(Color.black.opacity(0.97))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
        // 実際の描画高さをUIStateへ渡す（枠内の透明部分をクリック透過にする判定用）
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { ui.panelContentHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in ui.panelContentHeight = h }
            }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            // 閉じた状態と同じClawdアニメーションをヘッダーに表示
            ClawdWalker(range: 12, mode: store.clawdMode)
                .frame(width: 52, height: 27, alignment: .bottom)
            Spacer()
            HStack(spacing: 12) {
                statChip(color: Color(nsColor: .systemTeal), label: "実行中", count: store.workingCount)
                statChip(color: Color(nsColor: .systemBlue), label: "待ち", count: store.pendingCount)
                statChip(color: .green, label: "完了", count: store.doneCount)
                if store.errorCount > 0 {
                    statChip(color: .red, label: "エラー", count: store.errorCount)
                }
            }
        }
    }

    private func statChip(color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("エージェント待機中")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Text("Claude Code などを起動すると、ここに状況が表示されます")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

}

// MARK: - 休止中フォルダの細いタブ（1秒長押しで再開）

struct MutedFolderTab: View {
    let group: FolderGroup
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(group.color.opacity(0.5))
                .frame(width: 3, height: 9)
            Text("📁 \(group.name)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
            Text("休止中 — 長押しで再開")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.25))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.03)))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 1.0) { restore() }
    }
}

// MARK: - フォルダグループカード（同一フォルダの複数エージェントを囲う）

struct GroupCard: View {
    let group: FolderGroup
    let actions: NotchActions
    let blinkPhase: Bool
    var enterTargetId: String?
    /// 詳細カードを広げてよい唯一のセッションID
    var detailId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(group.color)
                    .frame(width: 4, height: 14)
                Text("📁 \(group.name)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text("\(group.sessions.count) エージェント")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)

            VStack(spacing: 4) {
                ForEach(group.sessions) { s in
                    SessionRow(
                        session: s,
                        actions: actions,
                        inGroup: true,
                        blinkPhase: blinkPhase,
                        enterTargetId: enterTargetId,
                        showDetail: s.id == detailId
                    )
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(group.color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(group.color.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - セッション行

struct SessionRow: View {
    let session: AgentSession
    let actions: NotchActions
    var inGroup = false
    var blinkPhase = true
    /// Enterで承認できるセッションのID（この行が対象なら「はい（Enter）」と表示する）
    var enterTargetId: String?
    /// 承認・質問の詳細カードを広げるか。パネルが画面を覆わないよう、
    /// 広げるのは一度に1件だけ（2件目以降は存在だけ示す）
    var showDetail = true
    @State private var hovering = false

    /// 承認カードに出す差分の最大行数。残りは「…他N行」で示す
    static let maxDiffLines = 6

    private var isPending: Bool {
        session.state == .waitingApproval || session.state == .waitingInput
    }

    var body: some View {
        let blinkColor = session.blinkColor
        VStack(alignment: .leading, spacing: 8) {
            headerRow(blinkColor: blinkColor)

            if showDetail {
                // 承認待ちは最初から内容と承認ボタンを展開表示する
                if session.state == .waitingApproval, let p = session.permission {
                    approvalDetail(p)
                }
                if let q = session.question, session.state == .waitingInput {
                    questionCard(q)
                }
            } else if isPending {
                pendingHint
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground(blinkColor: blinkColor))
        .animation(.easeInOut(duration: 1.1), value: blinkPhase)
        .onHover { hovering = $0 }
    }

    private func headerRow(blinkColor: NSColor?) -> some View {
        HStack(spacing: 10) {
                Circle()
                    .fill(Color(nsColor: blinkColor ?? session.stateColor))
                    .frame(width: 8, height: 8)
                    .opacity(blinkColor != nil && !blinkPhase ? 0.25 : 1.0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(inGroup ? session.agentLabel : session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(session.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: session.stateColor))
                        .lineLimit(1)
                }

                Spacer()

                if !inGroup {
                    badge(session.agentLabel)
                }
                if !session.terminal.isEmpty, session.terminal != "Cursor", session.terminal != "VS Code" {
                    badge(session.terminal)
                }
                Text(session.elapsedText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))

                // エラーは「了解」で点滅を消せる（完了はボタンなし・4秒後に自動了解）
                if session.state == .error, !session.acknowledged {
                    Button(action: { actions.acknowledge(session) }) {
                        Text("了解")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                }
            }
        .contentShape(Rectangle())
        .onTapGesture { actions.jump(session) }
    }

    /// 詳細カードを広げない待ち行の代わり。内容は出さず、あることだけ伝える
    private var pendingHint: some View {
        HStack(spacing: 6) {
            Text(session.state == .waitingApproval ? "承認待ち" : "質問あり")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: .systemBlue))
            Text("— 先の1件に回答すると内容が出ます（行をクリックで画面へ）")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.07)))
    }

    private func rowBackground(blinkColor: NSColor?) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                blinkColor.map { Color(nsColor: $0).opacity(blinkPhase ? 0.30 : 0.08) }
                    ?? (hovering ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
            )
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
    }

    /// 承認待ちの詳細：AIが実行しようとしている内容の全文＋Claude Codeと同じ並びの選択肢
    private func approvalDetail(_ p: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("🔵")
                    .font(.system(size: 9))
                Text(p.summary)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(nsColor: .systemBlue))
                    .lineLimit(1)
                Spacer()
            }
            if !p.lines.isEmpty {
                // ここもScrollViewは使わない（展開パネル側と同じクラッシュ経路に乗るため）。
                // ノッチは1.5秒で自動的に閉じる一覧なので、そもそもスクロールできない。
                // 全文はジャンプ先の画面で見る前提で、先頭数行だけ出して残りは件数で示す。
                let shown = p.lines.prefix(Self.maxDiffLines)
                let rest = p.lines.count - shown.count
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(diffColor(line))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if rest > 0 {
                        Text("…他 \(rest) 行")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            if session.hookControlled && !session.awaitingHookDecision {
                // hookは解放済み（＝そのAIの画面に通常のダイアログが出ている）。
                // ここで承認しても別のウィンドウに入る恐れがあるので、画面へ誘導する
                handOffToScreen("この承認は画面のダイアログで回答してください")
            } else {
                VStack(spacing: 4) {
                    approvalOption(1, session.id == enterTargetId ? "はい（Enter）" : "はい", accent: true) {
                        actions.allow(session)
                    }
                    approvalOption(2, "はい、今後は確認しない") { actions.allowAlways(session) }
                    approvalOption(3, "いいえ — 拒否してAIに伝える") { actions.deny(session) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
    }

    /// ノッチからは答えられないときの案内（誤送信を避けて画面へ誘導する）
    private func handOffToScreen(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
            Button(action: { actions.jump(session) }) {
                Text("この画面を開く")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.92)))
            }
            .buttonStyle(.plain)
        }
    }

    private func approvalOption(_ n: Int, _ label: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(n)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(accent ? .black.opacity(0.6) : .white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(accent ? Color.black.opacity(0.1) : Color.white.opacity(0.12)))
                Text(label)
                    .font(.system(size: 12, weight: accent ? .semibold : .regular))
                    .foregroundColor(accent ? .black : .white)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(accent ? Color.white.opacity(0.92) : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func questionCard(_ q: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("💬")
                    .font(.system(size: 11))
                Text(q.text.isEmpty ? "エージェントからの質問" : q.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: .systemBlue))
                    .lineLimit(2)
            }
            if q.options.isEmpty {
                Button(action: { actions.jump(session) }) {
                    Text("ターミナルで回答する")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(q.options.prefix(4).enumerated()), id: \.offset) { i, opt in
                        Button(action: { actions.answer(session, i + 1) }) {
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
                                Text(opt)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.06)))
    }

    private func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+") { return Color(nsColor: .systemGreen) }
        if line.hasPrefix("-") { return Color(nsColor: .systemRed) }
        return .white.opacity(0.7)
    }
}
