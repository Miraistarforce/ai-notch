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
    var deny: (AgentSession) -> Void
    var answer: (AgentSession, Int) -> Void
}

final class NotchWindowController {
    let panel: NSPanel
    let store: SessionStore
    let ui = UIState()
    private var collapseWork: DispatchWorkItem?
    /// 完了通知などでパネルを一時的に開いている期限
    private var flashUntil = Date.distantPast

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
                TerminalControl.approve(s)
                self?.store.markDecisionSent(s.id, text: "許可を送信しました…")
            },
            deny: { [weak self] s in
                TerminalControl.deny(s)
                self?.store.markDecisionSent(s.id, text: "拒否を送信しました…")
            },
            answer: { [weak self] s, i in
                TerminalControl.answer(s, option: i)
                self?.store.markDecisionSent(s.id, text: "回答 \(i) を送信しました…")
            }
        )
        let root = NotchRootView(store: store, ui: ui, actions: actions)
        panel.contentView = NSHostingView(rootView: root)
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        var notchWidth: CGFloat = 190
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        let barHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 36
        ui.notchWidth = notchWidth
        ui.barHeight = barHeight

        let size: CGSize = ui.expanded
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
        if store.needsAttention {
            setExpanded(true)
        } else if !ui.hovering {
            collapseSoon()
        }
    }

    /// 完了時などにパネルを一時的に自動オープンする
    func flashOpen(seconds: TimeInterval = 8) {
        flashUntil = Date().addingTimeInterval(seconds)
        setExpanded(true)
        collapseSoon(after: seconds + 0.2)
    }

    private func hoverChanged(_ inside: Bool) {
        ui.hovering = inside
        if inside {
            collapseWork?.cancel()
            setExpanded(true)
        } else {
            collapseSoon()
        }
    }

    private func collapseSoon(after: TimeInterval = 0.4) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.ui.hovering && !self.store.needsAttention && Date() >= self.flashUntil {
                self.setExpanded(false)
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func setExpanded(_ e: Bool) {
        guard ui.expanded != e else { return }
        ui.expanded = e
        reposition()
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
