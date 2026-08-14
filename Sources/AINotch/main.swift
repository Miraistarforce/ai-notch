import AppKit

// AI Notch — ノッチ型AIエージェントモニター
// Claude Code / Codex / Gemini などのCLIエージェントの状況をノッチに表示し、
// ジャンプ・許可・質問回答をノッチから操作する。

// 落ちた理由が分かるように、NSApplicationを作る前から例外を記録する
CrashLog.install()

// すでに動いていれば黙って終わる。exit(0)＝正常終了なので、
// launchd の KeepAlive（SuccessfulExit: false）でも復帰させられない。
if SingleInstance.anotherIsRunning() {
    NSLog("AINotch: すでに起動しているため、このプロセスは終了します")
    exit(0)
}

// AppKitのイベントループ内で投げられた例外を拾うため、NSApplicationのサブクラスを使う。
// sharedApplication はレシーバのクラスでインスタンスを作るので、これで差し替わる。
let app = AINotchApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
