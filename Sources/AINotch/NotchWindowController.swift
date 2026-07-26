import AppKit
import SwiftUI

final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var notchWidth: CGFloat = 190
    @Published var barHeight: CGFloat = 34
    /// 展開パネルの実際の描画高さ（クリック透過の判定用。再描画不要なので非Published）
    var panelContentHeight: CGFloat = 0
}

/// 承認カード表示中だけ有効になるグローバルEnterキー監視（CGEventTap）。
/// Enterを消費して「はい」を選択する。アクセシビリティ許可がないと何もしない。
private final class ApprovalKeyMonitor {
    /// Enterが押されたときに呼ばれる。trueを返すとキーイベントを消費する
    var onEnter: (() -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() {
        guard tap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ApprovalKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = monitor.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                // 36 = Return, 76 = テンキーEnter
                if keyCode == 36 || keyCode == 76, monitor.onEnter?() == true {
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
    }

    deinit { stop() }
}

/// 見えているコンテンツの外側（ウィンドウ枠内の透明部分）へのクリックを
/// 下のウィンドウに通すホスティングビュー
private final class PassthroughHostingView: NSHostingView<NotchRootView> {
    var interactiveHeight: () -> CGFloat = { 0 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let fromTop = isFlipped ? p.y : bounds.height - p.y
        guard fromTop <= interactiveHeight() else { return nil }
        return super.hitTest(point)
    }
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

    // ゴースト化：バー（ノッチ上部の帯）に0.3秒マウスを置くと半透明＋クリック透過になり、
    // バーに隠れたメニューバー項目を見て・クリックできる。マウスが離れたら元に戻る。
    private var ghostTimer: Timer?
    private var ghostHoverStart: Date?
    private var ghosted = false
    private static let ghostDelay: TimeInterval = 0.3
    private static let ghostAlpha: CGFloat = 0.18

    // 展開パネルは自動的に閉じる（マウスが乗っている間は閉じない）。
    // 完了通知だけで開いたときは1秒、それ以外（承認待ち・エラー等）は1.5秒。
    private var autoCloseWork: DispatchWorkItem?
    private static let autoCloseDelay: TimeInterval = 1.5
    private static let autoCloseDelayDone: TimeInterval = 1.0

    // ノッチ展開中に承認待ちがあるときだけ、Enterキーで「はい」を選択できる
    private let keyMonitor = ApprovalKeyMonitor()

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
                self?.collapseAfterDecision()
            },
            allowAlways: { [weak self] s in
                if s.awaitingHookDecision {
                    self?.store.decide(s.id, decision: "allow_always")
                } else {
                    TerminalControl.answer(s, option: 2)
                    self?.store.markDecisionSent(s.id, text: "許可（今後確認なし）を送信しました…")
                }
                self?.collapseAfterDecision()
            },
            deny: { [weak self] s in
                if s.awaitingHookDecision {
                    self?.store.decide(s.id, decision: "deny")
                } else {
                    TerminalControl.deny(s)
                    self?.store.markDecisionSent(s.id, text: "拒否を送信しました…")
                }
                self?.collapseAfterDecision()
            },
            answer: { [weak self] s, i in
                TerminalControl.answer(s, option: i)
                self?.store.markDecisionSent(s.id, text: "回答 \(i) を送信しました…")
                self?.collapseAfterDecision()
            },
            acknowledge: { [weak self] s in
                self?.store.acknowledge(s.id)
            }
        )
        let root = NotchRootView(store: store, ui: ui, actions: actions)
        let host = PassthroughHostingView(rootView: root)
        host.interactiveHeight = { [weak self] in
            guard let self else { return 0 }
            if self.ui.expanded {
                let h = self.ui.panelContentHeight
                return h > 0 ? h : Self.expandedHeight
            }
            return self.ui.barHeight
        }
        panel.contentView = host

        // ノッチの外側をクリックしたら閉じる（他アプリへのクリックはグローバルモニターで拾う）
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.ui.expanded else { return }
            self.dismissed = true
            self.setExpanded(false)
        }

        // ノッチ展開中の承認待ちはEnterで「はい」（承認ボタンと同じ処理）
        keyMonitor.onEnter = { [weak self] in
            guard let self, self.ui.expanded else { return false }
            guard let s = self.store.activeSessions.first(where: { $0.state == .waitingApproval }) else { return false }
            DispatchQueue.main.async {
                if s.awaitingHookDecision {
                    self.store.decide(s.id, decision: "allow")
                } else {
                    TerminalControl.approve(s)
                    self.store.markDecisionSent(s.id, text: "許可を送信しました…")
                }
                self.collapseAfterDecision()
            }
            return true
        }
    }

    /// Enterキー監視は「ノッチ展開中かつ承認待ちあり」のときだけ有効にする
    private func updateKeyCapture() {
        let hasApproval = store.activeSessions.contains { $0.state == .waitingApproval }
        if ui.expanded && hasApproval {
            keyMonitor.start()
        } else {
            keyMonitor.stop()
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
        updateKeyCapture()
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
        ghostTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
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
        guard ui.expanded != e else {
            updateKeyCapture()
            return
        }
        if e {
            // 先にウィンドウを広げてから、SwiftUI側で「ノッチから伸びる」アニメーションを再生
            applyFrame(expanded: true)
            ui.expanded = true
            scheduleAutoClose()
        } else {
            autoCloseWork?.cancel()
            // 縮むアニメーションを見せてからウィンドウを小さくする
            ui.expanded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                guard let self, !self.ui.expanded else { return }
                self.applyFrame(expanded: false)
            }
        }
        updateKeyCapture()
    }

    /// 承認・質問に回答した後は、マウスが乗っていても0.5秒で閉じる。
    /// ただし他のセッションの通知（承認待ち等）がまだ残っている場合は開いたままにする。
    private func collapseAfterDecision() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.ui.expanded else { return }
            guard self.store.attentionCount == 0 else { return }
            self.dismissed = true
            self.setExpanded(false)
        }
    }

    /// 展開から一定時間後に自動で閉じる（完了のみ=1秒、それ以外=1.5秒）。
    /// マウスが乗っている間は閉じず、dismissed だけ立てて、
    /// マウスが離れたとき（collapseSoon）に閉じる。
    private func scheduleAutoClose() {
        autoCloseWork?.cancel()
        let attention = store.activeSessions.filter { $0.blinkColor != nil }
        let doneOnly = !attention.isEmpty && attention.allSatisfy { $0.state == .done }
        let delay = doneOnly ? Self.autoCloseDelayDone : Self.autoCloseDelay
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.ui.expanded else { return }
            self.dismissed = true
            if !self.ui.hovering {
                self.setExpanded(false)
            }
        }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
