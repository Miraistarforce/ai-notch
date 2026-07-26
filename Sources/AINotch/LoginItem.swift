import AppKit
import Foundation
import ServiceManagement

enum LoginItemError: LocalizedError {
    case notBundled
    case requiresApproval
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "自動起動は .app バンドルから起動したときだけ設定できます（make run で起動し直してください）。"
        case .requiresApproval:
            return "macOSの承認待ちです。システム設定 → 一般 → ログイン項目 で AI Notch をオンにしてください。"
        case .failed(let message):
            return "自動起動の設定に失敗しました：\(message)"
        }
    }
}

/// ログイン時の自動起動（SMAppService.mainApp = このアプリ自身をログイン項目に登録する）。
/// 登録先はいま動いている .app バンドルのパスなので、バンドルを別の場所へ移したら
/// オフ→オンし直す必要がある。状態の正はmacOS側（SMAppService.status）に置き、
/// アプリ内には保存しない（システム設定から切られたときにUIがズレないため）。
final class LoginItem {
    static let shared = LoginItem()

    private var service: SMAppService { .mainApp }

    /// .app バンドルとして起動しているか（swift run の生バイナリでは登録できない）
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    var isEnabled: Bool { service.status == .enabled }

    /// システム設定側でユーザーが明示的に止めている状態
    var needsApproval: Bool { service.status == .requiresApproval }

    /// 登録されるバンドルのパス（設定画面に出して、どれが起動するかを分かるようにする）
    var bundlePath: String { Bundle.main.bundleURL.path }

    func setEnabled(_ on: Bool) throws {
        guard isAvailable else { throw LoginItemError.notBundled }
        do {
            if on {
                guard service.status != .enabled else { return }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return }
                try service.unregister()
            }
        } catch {
            throw LoginItemError.failed(error.localizedDescription)
        }
        if on && service.status == .requiresApproval {
            throw LoginItemError.requiresApproval
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 起動引数からの一括設定（`open dist/AINotch.app --args --enable-login-item`）。
    /// GUIを触らずにオン/オフしたいとき用。
    func applyLaunchArguments(_ arguments: [String]) {
        let on: Bool
        if arguments.contains("--enable-login-item") {
            on = true
        } else if arguments.contains("--disable-login-item") {
            on = false
        } else {
            return
        }
        do {
            try setEnabled(on)
            NSLog("AINotch: 自動起動を\(on ? "オン" : "オフ")にしました（\(bundlePath)）")
        } catch {
            NSLog("AINotch: 自動起動の設定に失敗 \(error.localizedDescription)")
        }
    }
}
