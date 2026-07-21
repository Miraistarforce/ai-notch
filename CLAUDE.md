# mac-ai-notch 開発ルール

ノッチ型AIエージェントモニター「AI Notch」。概要・セットアップは `README.md` を先に読むこと。

## 技術構成

- **純Swift**（SwiftPM、依存パッケージなし）。macOS 14+、Swift 5.9+
- UI: SwiftUI + AppKit（NSPanel、`.borderless` + `.nonactivatingPanel`、level `.statusBar`）
- サーバー: Network.framework（NWListener）の極小HTTP実装。127.0.0.1:43110
- ターミナル制御: `/usr/bin/osascript` 経由のAppleScript

## ファイル構成

| ファイル | 役割 |
|---------|------|
| `Sources/AINotch/AppDelegate.swift` | 起動・メニューバーアイテム・サーバー接続 |
| `Sources/AINotch/SessionStore.swift` | セッション状態管理と**日本語ステータス変換**（イベント→表示文言はすべてここ） |
| `Sources/AINotch/EventServer.swift` | HTTPサーバー（POST /event, GET /sessions, /health, /debug） |
| `Sources/AINotch/NotchWindowController.swift` | ノッチ位置計算・展開/折りたたみ制御 |
| `Sources/AINotch/NotchView.swift` | SwiftUIビュー（折りたたみバー・展開パネル・許可カード・質問カード） |
| `Sources/AINotch/TerminalControl.swift` | ジャンプとキー送信のAppleScript |
| `Sources/AINotch/HookSetup.swift` | AI検出と各設定ファイルへのhook登録・解除（Codexのtrust書き込み含む） |
| `Sources/AINotch/SettingsView.swift` | 連携設定ウィンドウ（メニューバーのClawdアイコンから開く） |
| `hooks/notch-hook.sh` | 各AIのhooksから呼ばれる転送スクリプト（引数で codex / gemini を指定） |
| `hooks/notch_post.py` | POST共通処理（全スクリプトが使用） |
| `hooks/install-hooks.sh` | `~/.claude/settings.json` への登録（バックアップ+冪等） |
| `hooks/notch-run` / `notch-report` | 汎用CLIラッパー / 報告CLI |

## 開発時の注意

1. ビルド・起動は `make run`（バンドル作成→open）。`swift run` だと**アクセシビリティ許可がバイナリパスに紐づいて毎回リセットされる**ので、権限テストは必ず `.app` バンドルで行う。
2. 再起動時は `pkill -f AINotch.app` してから `make run`（ポートが塞がったままになるため）。
3. 動作確認はスクリーンショットではなく `curl http://127.0.0.1:43110/debug` と `/sessions` を使う（画面収録権限がないと他アプリのウィンドウ同様スクショに写らない）。
4. hooksスクリプトは**必ず exit 0**（エージェント本体を止めないため）。タイムアウトは2秒厳守。
5. イベントスキーマを変えるときは `SessionStore.handle` と `hooks/notch_post.py` の両方を更新。
6. `~/.codex/config.toml` の notify は Claude Cowork が使用中。**上書き禁止**。
7. このフォルダは独立gitリポジトリ。コミットはこの中で行う。

## イベントAPI（POST /event）

Claude Code hooks形式（`hook_event_name`: SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / PermissionRequest / Notification / Stop / SessionEnd）と汎用形式（`event`: start / status / done / error / remove）の両方を受け付ける。ターミナル特定用に `tty` / `term_program` / `iterm_session_id` / `bundle_id` を付加する。

### 検証で判明した重要な挙動

- **許可プロンプトの検知は PermissionRequest hook を使う**。Notification hook（notification_type: permission_prompt）はVS Code/Cursor拡張環境では発火しないことを実測で確認済み（2026-07）。
- PermissionRequest はダイアログ表示直前に発火し、stdout に何も出力せず exit 0 すれば通常の許可フローに進む（副作用なし）。
- **ノッチの承認はキー送信ではなくhook応答で行う**：hookが `GET /decision?session=..&prompt=..` をポーリングし、決定を `hookSpecificOutput.decision`（behavior: allow は updatedInput 必須、deny は message 必須）として stdout に出力する。決定キーは `session_id:prompt_id`（並行する承認要求を区別するため。payload に `prompt_id` と `permission_suggestions` が含まれることを実測で確認）。
- ユーザーがそのAIの画面を開いたら decision="defer" でhookを解放し、通常のダイアログを出す。
- デバッグは `GET /events`（受信イベント履歴・最新50件）が最も確実。
- **Codex CLI（0.144時点）はClaude互換のhooksに対応**（`~/.codex/hooks.json`、イベント名・ペイロード・hookSpecificOutput応答すべて同形式。対応イベントは SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / PermissionRequest / Stop 等。SessionEnd / Notification は無い）。`config.toml` の notify には触らない。
- **Codexのhookはtrust承認が必要**：登録しただけでは実行されない。`config.toml` の `[hooks.state."<hooks.jsonパス>:<snake_caseイベント名>:<グループ番号>:<ハンドラ番号>"]` に `trusted_hash` を書くと信頼される。ハッシュは「`{"event_name":...,"hooks":[{"async":false,"command":...,"timeout":600(PermissionRequestは設定値),"type":"command"}]}` をキー昇順・圧縮・非ASCII非エスケープでJSON化 → SHA-256」（openai/codex の `version_for_toml`。2026-07に実測一致を確認）。`HookSetup.codexTrustHash` が実装。ズレたらCodex内の `/hooks` で承認し直せる。
- Codexの検証は `codex exec` を使うが、**必ず `</dev/null` を付ける**（stdinが開いたままだと入力待ちで固まる）。hookの状態確認は `codex app-server` に JSON-RPC で `initialize` → `hooks/list` を送ると trustStatus / currentHash が見える。
