import AppKit
import SwiftUI

final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var notchWidth: CGFloat = 190
    @Published var barHeight: CGFloat = 34
}

struct NotchActions {
    var hover: (Bool) -> Void
    var jump: (AgentSession) -> Void
    var allow: (AgentSession) -> Void
    var allowAlways: (AgentSession) -> Void
    var deny: (AgentSession) -> Void
    var answer: (AgentSession, Int) -> Void
    var acknowledge: (AgentSession) -> Void
}

final class NotchWindowController {
    let panel: NSPanel
    let store: SessionStore
    let ui = UIState()
    private var collapseWork: DispatchWorkItem?
    /// 外側クリックで一時的に閉じた状態（新しい通知が来るまで自動オープンを抑制）
    private var dismissed = false
    private var lastAttentionCount = 0
    private var outsideClickMonitor: Any?

    // ゴースト化：バー（ノッチ上部の帯）に2秒マウスを置くと半透明＋クリック透過になり、
    // バーに隠れたメニューバー項目を見て・クリックできる。マウスが離れたら元に戻る。
    private var ghostTimer: Timer?
    private var ghostHoverStart: Date?
    private var ghosted = false
    private static let ghostDelay: TimeInterval = 2.0
    private static let ghostAlpha: CGFloat = 0.18

    static let expandedWidth: CGFloat = 680
    static let expandedHeight: CGFloat = 520
    static let sideWidth: CGFloat = 130

    init(store: SessionStore) {
        self.store = store
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let actions = NotchActions(
            hover: { [weak self] inside in self?.hoverChanged(inside) },
            jump: { [weak self] s in
                TerminalControl.jump(s)
                self?.store.acknowledge(s.id)
                self?.collapseSoon()
            },
            allow: { [weak self] s in
                if s.awaitingHookDecision {
                    self?.store.decide(s.id, decision: "allow")
                } else {
                    TerminalControl.approve(s)
                    self?.store.markDecisionSent(s.id, text: "許可を送信しました…")
                }
            },
            allowAlways: { [weak self] s in
                if s.awaitingHookDecision {
                    self?.store.decide(s.id, decision: "allow_always")
                } else {
                    TerminalControl.answer(s, option: 2)
                    self?.store.markDecisionSent(s.id, text: "許可（今後確認なし）を送信しました…")
                }
            },
            deny: { [weak self] s in
                if s.awaitingHookDecision {
                    self?.store.decide(s.id, decision: "deny")
                } else {
                    TerminalControl.deny(s)
                    self?.store.markDecisionSent(s.id, text: "拒否を送信しました…")
                }
            },
            answer: { [weak self] s, i in
                TerminalControl.answer(s, option: i)
                self?.store.markDecisionSent(s.id, text: "回答 \(i) を送信しました…")
            },
            acknowledge: { [weak self] s in
                self?.store.acknowledge(s.id)
            }
        )
        let root = NotchRootView(store: store, ui: ui, actions: actions)
        panel.contentView = NSHostingView(rootView: root)

        // ノッチの外側をクリックしたら閉じる（他アプリへのクリックはグローバルモニターで拾う）
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.ui.expanded else { return }
            self.dismissed = true
            self.setExpanded(false)
        }
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    func reposition() {
        applyFrame(expanded: ui.expanded)
    }

    private func applyFrame(expanded: Bool) {
        guard let screen = targetScreen() else { return }
        var notchWidth: CGFloat = 190
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        let barHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 36
        // 同じ値の再代入でも @Published は通知するため、画面移動や開閉時の不要な再描画を避ける。
        if ui.notchWidth != notchWidth { ui.notchWidth = notchWidth }
        if ui.barHeight != barHeight { ui.barHeight = barHeight }

        let size: CGSize = expanded
            ? CGSize(width: max(Self.expandedWidth, notchWidth + 2 * Self.sideWidth), height: Self.expandedHeight)
            : CGSize(width: notchWidth + 2 * Self.sideWidth, height: barHeight)
        let f = screen.frame
        let rect = NSRect(
            x: (f.midX - size.width / 2).rounded(),
            y: f.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(rect, display: true)
    }

    func refreshPin() {
        // ゴースト中は自動オープンで邪魔しない（復帰時に改めて判定する）
        guard !ghosted else { return }
        // 新しい通知（点滅対象の増加）が来たら、外側クリックでの一時クローズを解除する
        let count = store.attentionCount
        if count > lastAttentionCount { dismissed = false }
        lastAttentionCount = count

        if count > 0 && !dismissed {
            setExpanded(true)
        } else if !ui.hovering {
            collapseSoon()
        }
    }

    private func hoverChanged(_ inside: Bool) {
        ui.hovering = inside
        if inside {
            collapseWork?.cancel()
            setExpanded(true)
            startGhostWatch()
        } else {
            if !ghosted { stopGhostWatch() }
            collapseSoon()
        }
    }

    // MARK: - ゴースト化（半透明＋クリック透過）

    /// バー領域（ノッチ上部の帯）の現在のスクリーン座標
    private func barRect() -> NSRect? {
        guard let screen = targetScreen() else { return nil }
        let width = ui.notchWidth + 2 * Self.sideWidth
        let f = screen.frame
        return NSRect(
            x: (f.midX - width / 2).rounded(),
            y: f.maxY - ui.barHeight,
            width: width,
            height: ui.barHeight
        )
    }

    private func startGhostWatch() {
        guard ghostTimer == nil else { return }
        ghostHoverStart = nil
        ghostTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.ghostTick()
        }
    }

    private func stopGhostWatch() {
        ghostTimer?.invalidate()
        ghostTimer = nil
        ghostHoverStart = nil
    }

    private func ghostTick() {
        guard let rect = barRect() else { return }
        let inBar = rect.contains(NSEvent.mouseLocation)

        if ghosted {
            // 透過中はパネルがイベントを受け取れないので、ここでマウスの離脱を監視する
            if !inBar { exitGhost() }
            return
        }
        if inBar {
            if ghostHoverStart == nil { ghostHoverStart = Date() }
            if Date().timeIntervalSince(ghostHoverStart ?? Date()) >= Self.ghostDelay {
                enterGhost()
            }
        } else {
            ghostHoverStart = nil
            // バーからもパネルからも離れていれば監視を止める（hover側のexitで再開される）
            if !ui.hovering { stopGhostWatch() }
        }
    }

    private func enterGhost() {
        ghosted = true
        ghostHoverStart = nil
        ui.hovering = false
        setExpanded(false)
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = Self.ghostAlpha
        }
    }

    private func exitGhost() {
        ghosted = false
        panel.ignoresMouseEvents = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        stopGhostWatch()
        refreshPin()
    }

    private func collapseSoon(after: TimeInterval = 0.4) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.ui.hovering && (!self.store.needsAttention || self.dismissed) {
                self.setExpanded(false)
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func setExpanded(_ e: Bool) {
        guard ui.expanded != e else { return }
        if e {
            // 先にウィンドウを広げてから、SwiftUI側で「ノッチから伸びる」アニメーションを再生
            applyFrame(expanded: true)
            ui.expanded = true
        } else {
            // 縮むアニメーションを見せてからウィンドウを小さくする
            ui.expanded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                guard let self, !self.ui.expanded else { return }
                self.applyFrame(expanded: false)
            }
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    func debugJSON() -> Data {
        var screens: [[String: Any]] = []
        for s in NSScreen.screens {
            screens.append([
                "frame": NSStringFromRect(s.frame),
                "safeTop": s.safeAreaInsets.top,
                "notchLeft": s.auxiliaryTopLeftArea.map(NSStringFromRect) ?? "nil",
                "notchRight": s.auxiliaryTopRightArea.map(NSStringFromRect) ?? "nil",
            ])
        }
        let info: [String: Any] = [
            "panelFrame": NSStringFromRect(panel.frame),
            "panelVisible": panel.isVisible,
            "panelAlpha": panel.alphaValue,
            "expanded": ui.expanded,
            "hovering": ui.hovering,
            "needsAttention": store.needsAttention,
            "mouseInPanel": panel.frame.contains(NSEvent.mouseLocation),
            "notchWidth": ui.notchWidth,
            "barHeight": ui.barHeight,
            "screens": screens,
        ]
        return (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted])) ?? Data("{}".utf8)
    }
}
