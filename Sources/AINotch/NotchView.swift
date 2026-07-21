import SwiftUI

struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    let actions: NotchActions

    var body: some View {
        ZStack(alignment: .top) {
            if ui.expanded {
                ExpandedPanel(store: store, ui: ui, actions: actions)
            } else {
                CollapsedBar(store: store, ui: ui)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { actions.hover($0) }
        .animation(.easeOut(duration: 0.15), value: ui.expanded)
    }
}

// MARK: - 折りたたみ状態（ノッチ左右にインジケーター）

struct CollapsedBar: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState

    var body: some View {
        HStack(spacing: 0) {
            // 左側：セッションごとの状態ドット
            HStack(spacing: 5) {
                if store.sessions.isEmpty {
                    Circle().fill(Color.gray.opacity(0.6)).frame(width: 6, height: 6)
                } else {
                    ForEach(store.sessions.prefix(5)) { s in
                        Circle()
                            .fill(Color(nsColor: s.stateColor))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .frame(width: NotchWindowController.sideWidth)

            Spacer(minLength: ui.notchWidth)

            // 右側：サマリーテキスト
            Group {
                if store.pendingCount > 0 {
                    Text("承認待ち \(store.pendingCount)")
                        .foregroundColor(.orange)
                } else if store.workingCount > 0 {
                    Text("実行中 \(store.workingCount)")
                        .foregroundColor(.green)
                } else if store.doneCount > 0 {
                    Text("完了 \(store.doneCount)")
                        .foregroundColor(Color(nsColor: .systemBlue))
                } else {
                    Text("待機")
                        .foregroundColor(.gray)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: NotchWindowController.sideWidth)
        }
        .frame(height: ui.barHeight)
        .frame(maxWidth: .infinity)
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
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(store.sessions) { s in
                                SessionRow(session: s, actions: actions)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
            }

            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("🏝 AIエージェント")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            HStack(spacing: 12) {
                statChip(color: .green, label: "実行中", count: store.workingCount)
                statChip(color: .orange, label: "待ち", count: store.pendingCount)
                statChip(color: Color(nsColor: .systemBlue), label: "完了", count: store.doneCount)
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

    private var footer: some View {
        Text("行をクリックでターミナルへ移動 ・ 許可/拒否はボタンから")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.35))
            .frame(maxWidth: .infinity)
    }
}

// MARK: - セッション行

struct SessionRow: View {
    let session: AgentSession
    let actions: NotchActions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(nsColor: session.stateColor))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(session.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: session.stateColor))
                        .lineLimit(1)
                }

                Spacer()

                badge(session.agentLabel)
                if !session.terminal.isEmpty, session.terminal != "Cursor", session.terminal != "VS Code" {
                    badge(session.terminal)
                }
                Text(session.elapsedText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            .contentShape(Rectangle())
            .onTapGesture { actions.jump(session) }

            if let p = session.permission, session.state == .waitingApproval {
                permissionCard(p)
            }

            if let q = session.question, session.state == .waitingInput {
                questionCard(q)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
        )
        .onHover { hovering = $0 }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
    }

    private func permissionCard(_ p: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("⚠️")
                    .font(.system(size: 11))
                Text(p.summary)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
            if !p.lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(p.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(diffColor(line))
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            HStack(spacing: 8) {
                Button(action: { actions.deny(session) }) {
                    Text("拒否")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Button(action: { actions.allow(session) }) {
                    Text("許可")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private func questionCard(_ q: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("💬")
                    .font(.system(size: 11))
                Text(q.text.isEmpty ? "エージェントからの質問" : q.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: .systemCyan))
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cyan.opacity(0.06)))
    }

    private func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+") { return Color(nsColor: .systemGreen) }
        if line.hasPrefix("-") { return Color(nsColor: .systemRed) }
        return .white.opacity(0.7)
    }
}
