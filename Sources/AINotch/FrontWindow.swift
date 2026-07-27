import AppKit
import ApplicationServices

/// ユーザーが今どのアプリの・どのウィンドウを見ているか。
/// VS Code / Cursor / ターミナルは1つのアプリで複数のエージェントを動かせるため、
/// バンドルIDだけではセッションを区別できない。ウィンドウタイトルまで見て判定する。
struct FrontContext {
    var bundleId: String = ""
    /// フォーカス中ウィンドウのタイトル。アクセシビリティ未許可・取得失敗なら空。
    var windowTitle: String = ""
}

/// アクセシビリティAPIでウィンドウ単位の特定・前面化を行う。
/// 許可がない環境では常に「特定できない」を返し、呼び出し側が保守的に振る舞う。
enum FrontWindow {
    /// 応答しないアプリで固まらないよう、AXの往復には短いタイムアウトを設ける
    private static let messagingTimeout: Float = 0.25
    private static let trustLock = NSLock()
    private static var trustCache: (value: Bool, at: Date)?

    /// アクセシビリティ許可の有無（描画のたびにTCCへ問い合わせないよう2秒キャッシュする）。
    /// 許可がないとウィンドウの特定もキー送信もできないため、呼び出し側の判定が変わる。
    static func isTrusted() -> Bool {
        trustLock.lock()
        defer { trustLock.unlock() }
        if let cache = trustCache, Date().timeIntervalSince(cache.at) < 2 { return cache.value }
        let value = AXIsProcessTrusted()
        trustCache = (value, Date())
        return value
    }

    /// 前面アプリとフォーカス中ウィンドウのタイトルを取得する
    static func probe(_ app: NSRunningApplication? = nil) -> FrontContext {
        guard let app = app ?? NSWorkspace.shared.frontmostApplication else { return FrontContext() }
        let bundleId = app.bundleIdentifier ?? ""
        guard isTrusted() else { return FrontContext(bundleId: bundleId) }
        return FrontContext(bundleId: bundleId, windowTitle: focusedWindowTitle(pid: app.processIdentifier))
    }

    static func focusedWindowTitle(pid: pid_t) -> String {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)
        guard let window = copyElement(axApp, kAXFocusedWindowAttribute) else { return "" }
        return copyString(window, kAXTitleAttribute)
    }

    /// 指定アプリのウィンドウのうち、タイトルに `name` を含むものがちょうど1つなら前面に出す。
    /// 0個または複数（＝どれが目的のウィンドウか決められない）なら false を返し、何もしない。
    static func raiseWindow(bundleId: String, containing name: String) -> Bool {
        guard isTrusted(), !bundleId.isEmpty, !name.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)
        guard let windows = copyElements(axApp, kAXWindowsAttribute) else { return false }
        let matches = windows.filter { copyString($0, kAXTitleAttribute).contains(name) }
        guard matches.count == 1, let target = matches.first else { return false }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        DispatchQueue.main.async { app.activate() }
        return true
    }

    // MARK: - AXヘルパー

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
}
