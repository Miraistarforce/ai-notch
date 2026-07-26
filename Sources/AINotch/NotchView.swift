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
        .onHover { actions.hover($0) }
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

                // 右側：状態ドット＋サマリーテキスト
                HStack(spacing: 6) {
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
                        }
                    }
                    summary(phase: phase)
                        .font(.system(size: 11, weight: .medium))
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

    @ViewBuilder
    private func summary(phase: Bool) -> some View {
        if store.errorCount > 0 {
            Text("エラー \(store.errorCount)")
                .foregroundColor(.red)
                .opacity(phase ? 1.0 : 0.4)
        } else if store.pendingCount > 0 {
            Text("承認待ち \(store.pendingCount)")
                .foregroundColor(Color(nsColor: .systemBlue))
                .opacity(phase ? 1.0 : 0.4)
        } else if store.workingCount > 0 {
            Text("実行中 \(store.workingCount)")
                .foregroundColor(Color(nsColor: .systemTeal))
        } else if store.doneCount > 0 {
            Text("完了 \(store.doneCount)")
                .foregroundColor(.green)
        } else {
            Text("待機")
                .foregroundColor(.gray)
        }
    }
}

// MARK: - 展開パネル

struct ExpandedPanel: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    let actions: NotchActions

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
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(folderGroups(store.sessions)) { group in
                                // 1秒長押しでフォルダ単位の休止⇔再開を切り替え
                                if store.mutedFolders.contains(group.id) {
                                    MutedFolderTab(group: group) {
                                        store.toggleMutedFolder(group.id)
                                    }
                                } else if group.sessions.count > 1 {
                                    GroupCard(group: group, actions: actions, blinkPhase: phase)
                                        .onLongPressGesture(minimumDuration: 1.0) {
                                            store.toggleMutedFolder(group.id)
                                        }
                                } else if let s = group.sessions.first {
                                    SessionRow(session: s, actions: actions, inGroup: false, blinkPhase: phase)
                                        .onLongPressGesture(minimumDuration: 1.0) {
                                            store.toggleMutedFolder(group.id)
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
            }

            Spacer(minLength: 10)
        }
        .frame(width: NotchWindowController.expandedWidth)
        .frame(maxHeight: NotchWindowController.expandedHeight, alignment: .top)
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
                    SessionRow(session: s, actions: actions, inGroup: true, blinkPhase: blinkPhase)
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
    @State private var hovering = false

    var body: some View {
        let blinkColor = session.blinkColor
        VStack(alignment: .leading, spacing: 8) {
            headerRow(blinkColor: blinkColor)

            // 承認待ちは最初から内容と承認ボタンを展開表示する
            if session.state == .waitingApproval, let p = session.permission {
                approvalDetail(p)
            }

            if let q = session.question, session.state == .waitingInput {
                questionCard(q)
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(p.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(diffColor(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 150)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            VStack(spacing: 4) {
                approvalOption(1, "はい（Enter）", accent: true) { actions.allow(session) }
                approvalOption(2, "はい、今後は確認しない") { actions.allowAlways(session) }
                approvalOption(3, "いいえ — 拒否してAIに伝える") { actions.deny(session) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
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
