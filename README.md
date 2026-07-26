# AI Notch — ノッチ型AIエージェントモニター

MacのノッチをAIエージェントの司令塔にするメニューバー常駐アプリ。[Vibe Island](https://vibeisland.app/) を参考に自作したもの。

AIの画面を開かなくても、ノッチにマウスを乗せるだけで **Claude Code / Codex / Gemini CLI などの複数エージェントが「今何をしているか」を日本語で確認**でき、そこから**ジャンプ・許可・質問回答**まで操作できる。

## できること

| 機能 | 説明 |
|------|------|
| モニター | 各セッションの状況を日本語で表示（「middleware.ts を編集中」「実行中: npm test」「完了 — クリックで移動」など）。タイトルは**開いているフォルダ名** |
| フォルダグループ | 同じフォルダで複数エージェントが動いている場合、色付きの枠でグループ化して表示（Cursor内のClaudeは `claude-cursor` のようにホスト併記） |
| 許可 (Approve) | 許可プロンプトが出た瞬間（PermissionRequest hook）に自動でパネルが開き、diffプレビュー付きで「許可 / 拒否」ボタンから操作できる |
| 質問回答 (Ask) | AskUserQuestion の選択肢をノッチに表示し、クリックで回答できる |
| ジャンプ (Jump) | 行クリックでそのセッションのターミナルへ移動。iTerm2 / Terminal.app は**該当タブまで正確にジャンプ**（Ghostty / Warp / VS Code / Cursor はアプリをアクティブ化） |
| 自動オープン＋点滅 | 承認待ち＝**青点滅**、完了＝**緑点滅**（30秒）、エラー＝**赤点滅**。いずれも自動でパネルが開く（完了は8秒後に自動で閉じる） |
| エラー検知 | `notch-run` の異常終了、明示的なerrorイベント、**実行中のまま10分間無応答**（API制限などの可能性）を赤点滅で通知 |
| サウンド | 許可待ちで Ping、完了で Glass、エラーで Basso が鳴る |
| Clawd | 閉じたノッチの左側を小さなClawd（[clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) 風のカニ）がゆっくり歩き回る。エージェントが動いていない間は立ち止まる |
| 連携設定 | メニューバーの**Clawdアイコンをクリック**すると設定画面が開き、検出されたAI（Claude Code / Codex / Gemini CLI）をトグルでオン/オフできる。設定ファイルへの登録・解除は自動（バックアップ付き） |

状態の色分け: 青緑＝実行中 / 🔵 承認・質問待ち（点滅） / 🟢 完了（点滅） / 🔴 エラー・停止（点滅） / ⚪ 待機。行クリックで確認済みになり点滅が止まる。

## セットアップ

必要なもの: macOS 14 以降、Xcode Command Line Tools（Swift 5.9+）。外部依存パッケージはなし。

```bash
git clone https://github.com/Miraistarforce/ai-notch.git
cd ai-notch

# ビルドして起動（メニューバーにClawdのアイコンが出る）
make run
```

起動したら **メニューバーのClawdアイコンをクリック** → 連携したいAIをオンにするだけ。hookスクリプトは自動で `~/Library/Application Support/AINotch/hooks/` に配置されるため、`dist/AINotch.app` を配布すれば**他の人のMacでもそのまま使える**（Swiftツールチェーン不要。アプリを起動してトグルをオンにするだけ）。

CLI派向けに `make install-hooks`（Claude Codeのみ登録）も残してある。

初回に **アクセシビリティ許可**（許可/拒否のキー送信用）と **オートメーション許可**（iTerm等のタブ切替用）を求められたら許可する。Clawdアイコン右クリック → 「アクセシビリティ設定を開く」からも開ける。

動作確認はClawdアイコン右クリック → 「テストイベントを表示」。

### ログイン時に自動起動

設定画面の「**ログイン時に自動起動**」をオンにする（メニューバーのClawdアイコン右クリックからも切り替えられる）。オンにするとmacOSのログイン項目に登録され、再起動・シャットダウンしてもログイン時に自動で立ち上がる。

- 登録されるのは**そのとき動いている `.app` バンドルのパス**。バンドルを別の場所へ移したらオフ→オンし直す。
- 状態の正はmacOS側（システム設定 → 一般 → ログイン項目）。そちらでオフにすると設定画面もオフになる。
- GUIを触らずに切り替えたいときは起動引数で指定できる。

```bash
open dist/AINotch.app --args --enable-login-item    # オン
open dist/AINotch.app --args --disable-login-item   # オフ
```

## 各エージェントとの連携方法

### Claude Code（フル対応）

設定画面でオンにすると `~/.claude/settings.json` に hooks が登録され、以降のセッションから自動で表示される（ターミナル / Cursor / VS Code 拡張すべて）。ツールごとの詳細ステータス・許可待ちのdiffプレビュー・質問の選択肢まで全部出る。

### Codex / ChatGPT（フル対応）

設定画面でオンにすると `~/.codex/hooks.json` にClaude互換のhooksが登録される。CodexのhookはSessionStart / UserPromptSubmit / PreToolUse / PostToolUse / PermissionRequest / Stop に対応しており、Claude Code同様にツール実行状況や許可待ちが表示される。

Codexには「未承認のhookは実行しない」trust機構があるため、オンにしたとき `~/.codex/config.toml` の専用ブロック（`# >>> AI Notch hooks trust >>>` 〜）に trusted_hash も自動で書き込む（設定画面のトグル操作をユーザーの同意とみなす）。`notify` 等の既存設定には一切触れない。Codexのアップデートでhookの正規化形式が変わって動かなくなった場合は、トグルをオフ→オンし直すか、Codex内で `/hooks` を開いて承認し直す。

### Gemini CLI（対応・未検証）

設定画面でオンにすると `~/.gemini/settings.json` に hooks（BeforeAgent / AfterAgent / BeforeTool / AfterTool 等）が登録される。イベント名はhook転送時にClaude相当へ変換している。手元にGemini CLIが無いため実機未検証。

### その他のCLI（ラッパー方式）

```bash
# hooks/ にPATHを通すか、フルパスで実行
./hooks/notch-run <コマンド>
NOTCH_TITLE="クエリ最適化" ./hooks/notch-run <コマンド>
```

開始・終了がノッチに表示される（実行中の詳細ステータスはなし）。

### 任意のスクリプトから報告

```bash
./hooks/notch-report start "バックエンド改修" --agent Codex --id my-task
./hooks/notch-report status "テスト実行中" --id my-task
./hooks/notch-report done "完了しました" --id my-task
```

## 仕組み

```
Claude Code hooks ──┐
Codex hooks ────────┼─ POST http://127.0.0.1:43110/event ──▶ AINotch.app（ノッチUI）
notch-run / report ─┘                                          │
                                                               ├─ ジャンプ: AppleScript（iTerm/Terminalはタブ特定）
                                                               ├─ 承認: PermissionRequest hookがノッチの決定を
                                                               │   ポーリング（GET /decision）→ allow/deny を
                                                               │   Claude Codeに直接返す（本物の承認。ダイアログ不要）
                                                               └─ フォールバック: System Events キー送信
```

承認の流れ：許可プロンプトが出るとhookが最大280秒ノッチの決定を待つ。ノッチで「1 はい / 2 はい、今後は確認しない / 3 いいえ」を選ぶとhook応答として返る。その間にそのAIの画面を自分で開くと、hookは即座に解放されて通常のダイアログが画面に表示される（ノッチと画面のどちらでも答えられる）。

- サーバーは 127.0.0.1 のみで待受（ポートは環境変数 `NOTCH_PORT`、デフォルト 43110）
- ターミナル特定は hooks が送る `TERM_PROGRAM` / `ITERM_SESSION_ID` / tty / `__CFBundleIdentifier` を使用
- 全処理ローカル完結。クラウド・アカウント・テレメトリなし

## デバッグ

```bash
curl http://127.0.0.1:43110/health    # 死活確認
curl http://127.0.0.1:43110/sessions  # 現在のセッション一覧
curl http://127.0.0.1:43110/debug     # パネル位置・画面情報
```

## 制限事項

- 許可/拒否はキー送信方式のため、ターミナル側のプロンプトが想定と違う配置だと効かないことがある（その場合はジャンプして直接操作）
- 許可した後も、実行が長いツールの場合は完了（PostToolUse）まで「許可待ち」表示が残ることがある
- Notification hookは環境によって発火しないため、許可検知は PermissionRequest hook を使用している（`make install-hooks` で登録される）
- Ghostty / Warp はAppleScript非対応のためアプリのアクティブ化のみ（タブ特定不可）
- Cursor / Claude Cowork などGUIアプリのエージェントは、Claude Code hooks経由（Cursor内のClaude Code拡張）以外は自動検知できない

## コントリビュート

Issue / Pull Request どちらも歓迎。開発時のルールと内部構成は [AGENTS.md](AGENTS.md) を参照。バグ報告には macOS のバージョン、使っているAI（Claude Code / Codex / Gemini CLI）とターミナル、`curl http://127.0.0.1:43110/events` の出力があると助かる。

## ライセンス

[MIT](LICENSE) © 2026 合同会社ミライスターフォース
