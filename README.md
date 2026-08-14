# AI Notch — ノッチ型AIエージェントモニター

MacのノッチをAIエージェントの司令塔にするメニューバー常駐アプリ。[Vibe Island](https://vibeisland.app/) を参考に自作したもの。

AIの画面を開かなくても、ノッチにマウスを乗せるだけで **Claude Code / Codex / Gemini CLI などの複数エージェントが「今何をしているか」を日本語で確認**でき、そこから**ジャンプ・許可・質問への移動**まで操作できる。

## できること

| 機能 | 説明 |
|------|------|
| モニター | 各セッションの状況を日本語で表示（「middleware.ts を編集中」「実行中: npm test」「完了 — クリックで移動」など）。タイトルは**開いているフォルダ名** |
| フォルダグループ | 同じフォルダで複数エージェントが動いている場合、色付きの枠でグループ化して表示（Cursor内のClaudeは `claude-cursor` のようにホスト併記） |
| 許可 (Approve) | 許可プロンプトが出た瞬間（PermissionRequest hook）に自動でパネルが開き、diffプレビュー付きで「許可 / 拒否」ボタンから操作できる |
| 許可の自動化 (Skip) | 設定の「**許可を自動で出す**」をオンにすると、ツール実行の許可をノッチが自動で許可する（確認なし）。**AIからの質問は対象外**で必ず人間が答える。既定はオフ |
| 質問 (Ask) | AIからの質問（AskUserQuestion）は**許可とは別扱い**。質問文と選択肢を表示し、「**質問に答える**」ボタンでそのAIのウィンドウへ移動する（回答は画面側で行う） |
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

### 許可を自動で出す（Permission Request Skip）

設定画面の「**許可を自動で出す**」をオンにすると、ツール実行の許可要求（ファイル編集・コマンド実行など）をノッチが**その場で自動的に許可**する。確認は出ず、ノッチには「自動で許可: Bash: npm test」のように何を通したかだけが残る（点滅もパネルの自動オープンもしない）。オンの間は展開パネルのヘッダーに「自動許可 ON」と出る。

**AIからの質問（AskUserQuestion）はこの対象外**。質問は自動で答えず、これまでどおり「質問に答える」ボタンからその画面へ移動して人間が回答する。「作業の許可は全部OK、判断が要る質問だけ自分で読む」という使い方のための設定。

- 既定はオフ（＝すべての許可を人間が出す）。オフにすれば元の動作に戻る
- メニューバーのClawdアイコン右クリックからも切り替えられる（オンにするときだけ確認が出る）
- 削除やコマンド実行も含めて**すべての許可要求をそのまま許可する**（ツールごとの絞り込みはしない）
- 状態確認は `curl http://127.0.0.1:43110/debug` の `skipPermissionRequests`

### 自動起動と自動復帰

設定画面の「**ログイン時に自動起動**」をオンにする（メニューバーのClawdアイコン右クリックからも切り替えられる）。オンにすると launchd の LaunchAgent として登録され、ログイン時に自動で立ち上がるうえ、**万一クラッシュしても1秒ほどで自動的に復帰する**。

常駐アプリなので、落ちても画面には何も出ず黙って消える。復帰の仕組みがないと、気づかないまま何日も止まったままになる（実際に起きた）。そのためログイン項目ではなく launchd に任せている。

- 復帰するのは**異常終了したときだけ**。メニューの「AI Notch を終了」で終わらせた場合は生き返らない。
- 登録されるのは**そのとき動いている `.app` バンドルのパス**。バンドルを別の場所へ移したらオフ→オンし直す（設定画面が警告を出す）。
- 状態確認は `make agent-status`、または `curl http://127.0.0.1:43110/debug` の `supervised`（true なら自動復帰する状態）。
- GUIを触らずに切り替えたいときは起動引数で指定できる。

```bash
make install-agent                                  # 自動起動＋自動復帰を有効にして起動し直す
open dist/AINotch.app --args --enable-login-item    # オン（反映は次のログインから）
open dist/AINotch.app --args --disable-login-item   # オフ
make restart                                        # いま反映させたいとき
make uninstall-agent                                # 解除
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
                                                                   （送信先ウィンドウを特定できたときだけ）
```

承認の流れ：許可プロンプトが出るとhookが最大280秒ノッチの決定を待つ。ノッチで「1 はい / 2 はい、今後は確認しない / 3 いいえ」を選ぶとhook応答として返る。その間にそのAIの画面を自分で開くと、hookは即座に解放されて通常のダイアログが画面に表示される（ノッチと画面のどちらでも答えられる）。

承認は必ず「要求してきたセッション」に返る。決定は `セッションID:プロンプトID` に紐づけてhookへ返すため、別のエージェントに届くことはない。Cursor / VS Code のように**1つのアプリで複数のエージェント**が動く場合は、フォーカス中のウィンドウのタイトル（末尾がワークスペース名）でどのセッションを見ているかを判定する。特定できないときは「見ていない」扱いにしてノッチが承認を預かる。Enterでの承認も、相手が一意に決まるとき（承認待ちが1つ＋見ているアプリで別のエージェントが動いていない）だけ有効になる。

- サーバーは 127.0.0.1 のみで待受（ポートは環境変数 `NOTCH_PORT`、デフォルト 43110）
- ターミナル特定は hooks が送る `TERM_PROGRAM` / `ITERM_SESSION_ID` / tty / `__CFBundleIdentifier` を使用
- 全処理ローカル完結。クラウド・アカウント・テレメトリなし

## デバッグ

```bash
curl http://127.0.0.1:43110/health    # 死活確認
curl http://127.0.0.1:43110/sessions  # 現在のセッション一覧
curl http://127.0.0.1:43110/debug     # パネル位置・画面情報・常駐状態
```

ノッチが反応しなくなったときは、まずログを見る。

```bash
make agent-status                     # launchdの登録・稼働状況
cat ~/Library/Logs/AINotch/crash.log  # 未キャッチ例外（理由とスタック）
tail ~/Library/Logs/AINotch/launchd.err.log
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
