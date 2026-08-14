import AppKit
import Foundation

/// 未キャッチ例外を必ずファイルに残す。
///
/// 2026-08-09 のクラッシュは、AppKitの表示サイクル中に投げられた例外が誰にも捕まえられず
/// `-[NSApplication _crashOnException:]` でプロセスごと落ちたもの。メニューバー常駐
/// （`.accessory`）なので画面には何も出ず、原因がクラッシュレポートを掘るまで分からなかった。
/// ここで理由とスタックを `~/Library/Logs/AINotch/crash.log` に残す。
enum CrashLog {
    static var fileURL: URL {
        LoginItem.logDirectory.appendingPathComponent("crash.log")
    }

    /// クラッシュループになっても肥大化しないよう、この大きさを超えたら1世代だけ退避する
    private static let maxBytes = 1_000_000

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashLog.record(exception, source: "NSUncaughtExceptionHandler")
        }
    }

    /// AppKitのイベントループ内で投げられた例外は NSApplication が先に受け取るので、
    /// NSSetUncaughtExceptionHandler だけでは拾えない。
    /// AINotchApplication.reportException からも呼ぶこと。
    static func record(_ exception: NSException, source: String) {
        let entry = """
        ---- \(timestamp()) [\(source)] pid \(ProcessInfo.processInfo.processIdentifier)
        name:     \(exception.name.rawValue)
        reason:   \(exception.reason ?? "(なし)")
        userInfo: \(exception.userInfo.map { String(describing: $0) } ?? "(なし)")
        \(exception.callStackSymbols.joined(separator: "\n"))


        """
        NSLog("AINotch: 未キャッチ例外 \(exception.name.rawValue) — \(exception.reason ?? "")")
        append(entry)
    }

    /// 例外以外の「起動できなかった」系もここに残す（サーバーが立たない等）
    static func note(_ message: String) {
        NSLog("AINotch: \(message)")
        append("---- \(timestamp()) [note] \(message)\n\n")
    }

    private static func append(_ text: String) {
        let url = fileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }

        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

/// AppKitのイベントループ内で投げられた例外を記録するための NSApplication。
/// `reportException` はプロセスが落ちる直前に呼ばれるので、ここが最後の記録機会になる。
final class AINotchApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        CrashLog.record(exception, source: "reportException")
        super.reportException(exception)
    }
}
