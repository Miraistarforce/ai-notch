import AppKit
import SwiftUI

final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var notchWidth: CGFloat = 190
    @Published var barHeight: CGFloat = 34
    /// 展開パネルが伸びられる上限。画面が低いMac（13インチのAir等）でも
    /// はみ出さないよう、実際の画面高さに合わせて applyFrame が縮める
    @Published var maxPanelHeight: CGFloat = NotchWindowController.expandedHeight
    /// 展開パネルの実際の描画高さ（クリック透過の判定用。再描画不要なので非Published）
    var panelContentHeight: CGFloat = 0
    /// 枠で頭打ちにする前の、中身が本来必要としている高さ。
    /// panelContentHeight とほぼ同じなら収まっている。これより枠が小さいと下が切れる。
    var naturalContentHeight: CGFloat = 0
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
    /// いま実際に描かれている中身の大きさ（ウィンドウ上端・左右中央にそろえて描かれる）
    var interactiveSize: () -> CGSize = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let size = interactiveSize()
        let fromTop = isFlipped ? p.y : bounds.height - p.y
        guard fromTop >= 0, fromTop <= size.height,
              abs(p.x - bounds.midX) <= size.width / 2 else { return nil }
        return super.hitTest(point)
    }
}

/// ノッチから起こせる操作。質問（AskUserQuestion）への回答はここに無い＝
/// ノッチからは答えず、jump でそのAIの画面へ移動して画面側で答えてもらう。
struct NotchActions {
    var hover: (Bool) -> Void
    var jump: (AgentSession) -> Void
    var allow: (AgentSession) -> Void
    var allowAlways: (AgentSession) -> Void
    var deny: (AgentSession) -> Void
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
    /// 展開ウィンドウの高さ。パネルはScrollViewを持たず中身の分だけ伸びるので、
    /// 表示上限（詳細カード1枚＋残り4行＋あふれ表示）が収まる高さを枠として確保する。
    /// ここが中身より小さいと下が切れるうえ、contentRect が枠と一致して
    /// 透明な余白まで当たり判定に入ってしまうので、必ず余裕を持たせること。
    static let expandedHeight: CGFloat = 780
    /// 物理ノッチの左右に張り出す幅。ここはメニューバーの実在領域を覆うので、
    /// 隠す範囲が最小になるようClawdと状態ドットが収まるぎりぎりに留める。
    static let sideWidth: CGFloat = 70

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
                self?.decide(s, hookDecision: "allow", sending: "許可を送信中…", sent: "許可を送信しました") {
                    TerminalControl.approve(s, requirePreciseTarget: $0, completion: $1)
                }
            },
            allowAlways: { [weak self] s in
                self?.decide(s, hookDecision: "allow_always", sending: "許可（今後確認なし）を送信中…", sent: "許可（今後確認なし）を送信しました") {
                    TerminalControl.answer(s, option: 2, requirePreciseTarget: $0, completion: $1)
                }
            },
            deny: { [weak self] s in
                self?.decide(s, hookDecision: "deny", sending: "拒否を送信中…", sent: "拒否を送信しました") {
                    TerminalControl.deny(s, requirePreciseTarget: $0, completion: $1)
                }
            },
            acknowledge: { [weak self] s in
                self?.store.acknowledge(s.id)
            }
        )
        let root = NotchRootView(store: store, ui: ui, actions: actions)
        let host = PassthroughHostingView(rootView: root)
        host.interactiveSize = { [weak self] in self?.contentSize() ?? .zero }
        panel.contentView = host

        // ノッチの外側をクリックしたら閉じる（他アプリへのクリックはグローバルモニターで拾う）
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.ui.expanded else { return }
            self.dismissed = true
            self.setExpanded(false)
        }

        // ノッチ展開中の承認待ちはEnterで「はい」（承認ボタンと同じ処理）。
        // 対象を一意に決められるときだけ働く（store.enterApprovalTarget を参照）
        keyMonitor.onEnter = { [weak self] in
            guard let self, self.ui.expanded else { return false }
            guard let s = self.store.enterApprovalTarget else { return false }
            DispatchQueue.main.async {
                self.store.decide(s.id, decision: "allow")
                self.collapseAfterDecision()
            }
            return true
        }
    }

    /// 承認・回答の送信。hookで返せるならそちら（送信先が確実）、
    /// 返せないセッションだけキー送信にフォールバックする。
    /// 同じアプリで複数のエージェントが動いている場合は、ウィンドウを特定できないと送らない。
    private func decide(
        _ s: AgentSession,
        hookDecision: String?,
        sending: String,
        sent: String,
        keySend: (Bool, @escaping (Bool) -> Void) -> Void
    ) {
        if let hookDecision, s.awaitingHookDecision {
            store.decide(s.id, decision: hookDecision)
            collapseAfterDecision()
            return
        }
        store.markSending(s.id, text: sending)
        keySend(store.hasSibling(s)) { [weak self] ok in
            self?.store.markKeySendResult(
                s.id,
                success: ok,
                text: ok ? sent : "送信先の画面を特定できませんでした — 画面を開いて回答してください"
            )
        }
        collapseAfterDecision()
    }

    /// Enterキー監視は「ノッチ展開中かつEnterで承認できる相手が一意に決まる」ときだけ有効にする。
    /// （常時有効にすると、ユーザーが別のエージェントに打ったEnterまで横取りしてしまう）
    private func updateKeyCapture() {
        if ui.expanded, store.enterApprovalTarget != nil {
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
        // 画面が低いMac（13インチのAir等）では枠が画面からはみ出すので、そこで頭打ちにする
        let panelHeight = min(Self.expandedHeight, screen.frame.height - 40)
        // 同じ値の再代入でも @Published は通知するため、画面移動や開閉時の不要な再描画を避ける。
        if ui.notchWidth != notchWidth { ui.notchWidth = notchWidth }
        if ui.barHeight != barHeight { ui.barHeight = barHeight }
        if ui.maxPanelHeight != panelHeight { ui.maxPanelHeight = panelHeight }

        let size: CGSize = expanded
            ? CGSize(width: max(Self.expandedWidth, notchWidth + 2 * Self.sideWidth), height: panelHeight)
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

    /// ウィンドウ枠は描画内容より大きい（展開枠は 680x520 固定だが中身は必要な高さだけ。
    /// 閉じた直後も縮むアニメーションのため0.36秒は枠が大きいまま残る）。
    /// 枠内というだけでホバー扱いにすると、ノッチに被っていない位置にカーソルを
    /// 戻しただけで勝手に展開するので、実際に描かれている範囲かどうかで判定する。
    private func hoverChanged(_ insideWindow: Bool) {
        // ゴースト中（半透明＋クリック透過）はホバーを受け付けない。
        // 復帰はバーから離れたことを ghostTick が見て exitGhost で行う。
        guard !ghosted else { return }
        let inside = insideWindow && contentRect().contains(NSEvent.mouseLocation)
        // onContinuousHover は移動のたびに発火するので、変化したときだけ処理する
        guard ui.hovering != inside else { return }
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

    /// いま実際に描かれている中身の大きさ。ウィンドウ枠は閉じたあとも
    /// 0.36秒は展開サイズのまま残る（縮むアニメーションのため）ので、
    /// 当たり判定は枠ではなく必ずこの大きさで行う。
    private func contentSize() -> CGSize {
        if ui.expanded {
            let h = ui.panelContentHeight
            return CGSize(width: Self.expandedWidth, height: h > 0 ? h : ui.maxPanelHeight)
        }
        return CGSize(width: ui.notchWidth + 2 * Self.sideWidth, height: ui.barHeight)
    }

    /// 実際に描かれている範囲のスクリーン座標（ウィンドウ上端・左右中央にそろえて描かれる）
    private func contentRect() -> NSRect {
        let size = contentSize()
        let f = panel.frame
        let width = min(size.width, f.width)
        return NSRect(
            x: (f.midX - width / 2).rounded(),
            y: f.maxY - size.height,
            width: width,
            height: size.height
        )
    }

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
        // メニューを開いている間やドラッグ中はランループが .eventTracking に移るので、
        // 既定モードのタイマーだとその間止まる。ゴースト（半透明＋クリック透過）は
        // このタイマーでしか解除できないため、止まると「消えたまま反応しない」状態に
        // 見えてしまう。.common に入れてトラッキング中も動かす。
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.ghostTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        ghostTimer = timer
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
            // 承認の送信先判定に効く情報（誤送信の切り分け用）
            "accessibilityTrusted": FrontWindow.isTrusted(),
            // launchd管理下なら落ちても自動復帰する。falseなら手動起動＝復帰しない
            "supervised": LoginItem.shared.isSupervised,
            // true ならツール実行の許可をノッチが自動で許可している（質問は対象外）
            "skipPermissionRequests": AppSettings.shared.skipPermissionRequests,
            "autoLaunchEnabled": LoginItem.shared.isEnabled,
            // AINotchApplication になっていれば、AppKit内で投げられた例外が
            // reportException 経由で crash.log に残る
            "applicationClass": NSApp?.className ?? "nil",
            "frontBundleId": store.frontContext.bundleId,
            "frontWindowTitle": store.frontContext.windowTitle,
            "enterApprovalTarget": store.enterApprovalTarget?.id ?? "",
            "panelFrame": NSStringFromRect(panel.frame),
            // ホバー・クリックの当たり判定に使う「実際に描かれている範囲」。
            // panelFrame より小さいのが正常（差分は透明な余白）
            "contentRect": NSStringFromRect(contentRect()),
            // 中身が本来必要な高さ。maxPanelHeight を超えていたら下が切れている＝
            // 表示件数（ExpandedPanel.maxVisibleSessions）を絞るか枠を広げる
            "naturalContentHeight": ui.naturalContentHeight,
            "maxPanelHeight": ui.maxPanelHeight,
            "contentClipped": ui.naturalContentHeight > ui.maxPanelHeight + 0.5,
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
