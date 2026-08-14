import AppKit
import Foundation
import ServiceManagement

enum LoginItemError: LocalizedError {
    case notBundled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "自動起動は .app バンドルから起動したときだけ設定できます（make run で起動し直してください）。"
        case .failed(let message):
            return "自動起動の設定に失敗しました：\(message)"
        }
    }
}

/// ログイン時の自動起動と、クラッシュしたときの自動復帰。
///
/// 以前は SMAppService.mainApp（ただのログイン項目）を使っていたが、これはログイン時に
/// 一度起動するだけで、落ちたら次のログインまで戻ってこない。常駐が前提のアプリなので
/// KeepAlive を持てる launchd の LaunchAgent
/// （`~/Library/LaunchAgents/jp.miraistarforce.ainotch.plist`）に移行した。
///
/// KeepAlive は `SuccessfulExit: false`＝**異常終了したときだけ**復帰させる。
/// メニューの「AI Notch を終了」は正常終了なので、意図して終了したものが
/// 勝手に生き返ることはない。
final class LoginItem {
    static let shared = LoginItem()

    static let label = "jp.miraistarforce.ainotch"
    /// クラッシュループになったときに再起動を間引く秒数
    private static let throttleInterval = 10

    private var domain: String { "gui/\(getuid())" }

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    /// launchd が stdout/stderr を書き出す先。クラッシュ直前のNSLogがここに残る
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AINotch")
    }

    /// launchd に起動させる実行ファイル（.app バンドル内のバイナリ）
    private var executablePath: String? { Bundle.main.executableURL?.path }

    /// .app バンドルとして起動しているか（swift run の生バイナリでは登録しない）
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && executablePath != nil
    }

    /// 登録されるバンドルのパス（設定画面に出して、どれが起動するか分かるようにする）
    var bundlePath: String { Bundle.main.bundleURL.path }

    /// 登録済みか。plistの有無で判定する（launchctlを毎回叩くとUI更新が重い）
    var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// 登録はされているが、いま動いているバンドルと違うパスが書かれている状態。
    /// dist/ を移動・削除したまま放置するとここに落ちるので、設定画面で警告して登録し直させる。
    var needsReregister: Bool {
        guard isEnabled, let registered = registeredExecutablePath() else { return false }
        return registered != executablePath
    }

    /// このプロセスが launchd の管理下で動いているか（＝落ちても復帰する状態か）。
    /// LaunchServices（open）経由で起動したときはジョブラベルではなく
    /// `application.<bundleId>.…` が入るので区別できる。
    var isSupervised: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Self.label
    }

    func setEnabled(_ on: Bool) throws {
        guard isAvailable else { throw LoginItemError.notBundled }
        if on { try enable() } else { try disable() }
    }

    private func enable() throws {
        guard let exe = executablePath else { throw LoginItemError.notBundled }

        // 旧方式のログイン項目が残っていると、ログイン時に launchd と二重に起動してしまう
        try? SMAppService.mainApp.unregister()

        do {
            try FileManager.default.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try plistData(executable: exe).write(to: plistURL, options: .atomic)
        } catch {
            throw LoginItemError.failed(error.localizedDescription)
        }

        // disable されたジョブは bootstrap できないので、先に解除しておく
        _ = launchctl(["enable", "\(domain)/\(Self.label)"])

        // すでに読み込まれているときは bootout → bootstrap で読み込み直したくなるが、
        // **このプロセス自身が launchd の管理対象だと bootout で自分が殺され、
        // 続きの bootstrap が実行されないままアプリが消える**。
        // 読み込み直しが要る場合は外部（make install-agent）から行う。
        // plistは書き換え済みなので、次のログインからは新しい内容で起動する。
        guard !isLoaded else { return }
        let result = launchctl(["bootstrap", domain, plistURL.path])
        guard result.status == 0 else {
            throw LoginItemError.failed("launchctl bootstrap が失敗しました（\(result.output)）")
        }
    }

    private func disable() throws {
        // ここでも bootout は使わない（launchd管理下だと自分を殺してしまう）。
        // disable + plist削除で「次のログインからは起動しない」状態にする。
        // いま動いているプロセスはそのまま動き続ける。
        _ = launchctl(["disable", "\(domain)/\(Self.label)"])
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            throw LoginItemError.failed(error.localizedDescription)
        }
    }

    private var isLoaded: Bool {
        launchctl(["print", "\(domain)/\(Self.label)"]).status == 0
    }

    private func plistData(executable: String) throws -> Data {
        let job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // 異常終了（クラッシュ）したときだけ復帰させる。
            // メニューの「終了」は正常終了なので生き返らない。
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": Self.throttleInterval,
            // UIを持つので省電力スロットリングの対象から外す
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": Self.logDirectory.appendingPathComponent("launchd.out.log").path,
            "StandardErrorPath": Self.logDirectory.appendingPathComponent("launchd.err.log").path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    private func registeredExecutablePath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let args = dict["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // 先に読み切ってから待つ（パイプが詰まるとwaitUntilExitが返らない）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
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
