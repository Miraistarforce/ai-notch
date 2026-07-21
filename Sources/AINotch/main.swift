import AppKit

// AI Notch — ノッチ型AIエージェントモニター
// Claude Code / Codex / Gemini などのCLIエージェントの状況をノッチに表示し、
// ジャンプ・許可・質問回答をノッチから操作する。

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
