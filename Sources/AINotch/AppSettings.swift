import Foundation

/// アプリ全体の設定（UserDefaultsに永続化）。
/// 設定画面・メニュー・SessionStore の3か所から同じ値を見るための入れ物。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let skipKey = "skipPermissionRequests"

    /// 許可の自動化（Permission Request Skip）。
    /// オンの間、ツール実行の**許可要求だけ**をノッチが自動で許可する。
    /// AIからの質問（AskUserQuestion）は対象外で、必ず人間が読んで答える。
    /// 既定はオフ（＝許可はすべて人間が出す）。
    @Published var skipPermissionRequests: Bool {
        didSet {
            guard skipPermissionRequests != oldValue else { return }
            UserDefaults.standard.set(skipPermissionRequests, forKey: Self.skipKey)
        }
    }

    private init() {
        skipPermissionRequests = UserDefaults.standard.bool(forKey: Self.skipKey)
    }
}
