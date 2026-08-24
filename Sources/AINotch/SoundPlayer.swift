import AppKit

/// 通知音の再生。
///
/// 許可待ち・エラーはmacOSのシステム音（Ping / Basso）をそのまま鳴らすが、
/// **タスク完了だけはアプリ同梱のmp3**（`Resources/Sounds/complete.mp3`）を鳴らす。
/// 作業中に何度も鳴るものなので音量は小さめに固定してある。
enum SoundPlayer {
    /// 完了音の音量（0〜1。システム音量に対する相対値）。
    /// 作業の邪魔にならないよう小さく鳴らす。
    static let completionVolume: Float = 0.2

    /// 同梱の完了音。`.app` バンドルからのみ見つかる
    /// （`swift run` では見つからないのでシステム音にフォールバックする）。
    private static let completionSound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "complete", withExtension: "mp3", subdirectory: "Sounds"),
              let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        sound.volume = completionVolume
        return sound
    }()

    /// 同梱の完了音を使えるか（`GET /debug` の確認用）
    static var hasCompletionSound: Bool { completionSound != nil }

    /// システム音を鳴らす（許可待ち＝Ping、エラー＝Basso）
    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// タスク完了の音。
    /// インスタンスは1つだけ使い回すので、鳴っている途中に次の完了が来たら
    /// 重ならずに頭から鳴り直す（複数セッションが同時に終わっても音が割れない）。
    static func playCompletion() {
        guard let sound = completionSound else {
            play("Glass")
            return
        }
        if sound.isPlaying { sound.stop() }
        sound.volume = completionVolume
        sound.play()
    }
}
