import AppKit
import Foundation

/// 二重起動の防止。
///
/// 常駐は launchd（LaunchAgent）に任せているが、`open dist/AINotch.app` や
/// Finderからのダブルクリックでも起動できるので、両方から立ち上がりうる。
/// 2つ動くとポート43110の取り合いになり、hookの届く先が不定になる。
enum SingleInstance {
    /// すでに別のAI Notchが動いているか。
    /// NSApplication を作る前に呼ぶ（このプロセスはまだLaunchServicesに登録されていないので
    /// 自分自身は数えられないが、念のためpidでも除外する）。
    static func anotherIsRunning() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains { $0.processIdentifier != mine && !$0.isTerminated }
    }
}
