# AI Notch — ノッチ型AIエージェントモニター

MacのノッチをAIエージェントの司令塔にするメニューバー常駐アプリ。[Vibe Island](https://vibeisland.app/) を参考に自作したもの。

AIの画面を開かなくても、ノッチにマウスを乗せるだけで **Claude Code / Codex / Gemini CLI などの複数エージェントが「今何をしているか」を日本語で確認**でき、そこから**ジャンプ・許可・質問回答**まで操作できる。

## できること

| 機能 | 説明 |
|------|------|
| モニター | 各セッションの状況を日本語で表示（「middleware.ts を編集中」「実行中: npm test」「完了 — クリックで移動」など） |
| 許可 (Approve) | ツール実行の許可待ちになると自動でパネルが開き、diffプレビュー付きで「許可 / 拒否」ボタンから操作できる |
| 質問回答 (Ask) | AskUserQuestion の選択肢をノッチに表示し、クリックで回答できる |
| ジャンプ (Jump) | 行クリックでそのセッションのターミナルへ移動。iTerm2 / Terminal.app は**該当タブまで正確にジャンプ**（Ghostty / Warp / VS Code / Cursor はアプリをアクティブ化） |
| サウンド | 許可待ちで Ping、完了で Glass が鳴る |

状態の色分け: 🟢 実行中 / 🟠 許可待ち / 🩵 質問待ち / 🔵 完了 / ⚪ 待機

## セットアップ

```bash
cd apps/mac-ai-notch

# 1. ビルドして起動（メニューバーに 🏝 が出る）
make run

# 2. Claude Code の hooks を登録（既存設定はバックアップしてからマージ）
make install-hooks
```

初回に **アクセシビリティ許可**（許可/拒否のキー送信用）と **オートメーション許可**（iTerm等のタブ切替用）を求められたら許可する。メニューバー 🏝 → 「アクセシビリティ設定を開く」からも開ける。

動作確認はメニューバー 🏝 → 「テストイベントを表示」。

### ログイン時に自動起動したい場合

システム設定 → 一般 → ログイン項目 に `dist/AINotch.app` を追加。

## 各エージェントとの連携方法

### Claude Code（フル対応）

`make install-hooks` で `~/.claude/settings.json` に hooks が登録され、以降のセッションから自動で表示される。タイトルは最初の指示文から自動生成。ツールごとの詳細ステータス・許可待ちのdiffプレビュー・質問の選択肢まで全部出る。

### Codex / Gemini CLI / その他のCLI（ラッパー方式）

```bash
# hooks/ にPATHを通すか、フルパスで実行
./hooks/notch-run codex
./hooks/notch-run gemini
NOTCH_TITLE="クエリ最適化" ./hooks/notch-run gemini
```

開始・終了がノッチに表示される（実行中の詳細ステータスはなし）。

Codexの `notify` 連携用に `hooks/codex-notify.sh` も用意してあるが、**このMacでは `~/.codex/config.toml` の notify を Claude Cowork（computer-use）が既に使用中**のため上書きしていない。使う場合はチェーンスクリプトを作って両方呼ぶこと。

### 任意のスクリプトから報告

```bash
./hooks/notch-report start "バックエンド改修" --agent Codex --id my-task
./hooks/notch-report status "テスト実行中" --id my-task
./hooks/notch-report done "完了しました" --id my-task
```

## 仕組み

```
Claude Code hooks ──┐
notch-run / report ─┼─ POST http://127.0.0.1:43110/event ──▶ AINotch.app（ノッチUI）
codex-notify.sh ────┘                                          │
                                                               ├─ ジャンプ: AppleScript（iTerm/Terminalはタブ特定）
                                                               └─ 許可/拒否/回答: System Events キー送信
                                                                  （許可=Return、拒否=Esc、選択肢=数字+Return）
```

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
- Ghostty / Warp はAppleScript非対応のためアプリのアクティブ化のみ（タブ特定不可）
- Cursor / Claude Cowork などGUIアプリのエージェントは、Claude Code hooks経由（Cursor内のClaude Code拡張）以外は自動検知できない
