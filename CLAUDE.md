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
| `Sources/AINotch/TerminalControl.swift` | ジャンプとキー送信のAppleScript（送信先ウィンドウを特定できたときだけ送る） |
| `Sources/AINotch/FrontWindow.swift` | アクセシビリティAPIでの**前面ウィンドウ特定**（タイトル取得・目的ウィンドウの前面化） |
| `Sources/AINotch/HookSetup.swift` | AI検出と各設定ファイルへのhook登録・解除（Codexのtrust書き込み含む） |
| `Sources/AINotch/SettingsView.swift` | 連携設定ウィンドウ（メニューバーのClawdアイコンから開く） |
| `Sources/AINotch/LoginItem.swift` | 自動起動＋クラッシュ時の自動復帰（launchd の LaunchAgent を生成・登録。起動引数 `--enable-login-item` / `--disable-login-item` にも対応） |
| `Sources/AINotch/CrashLog.swift` | 未キャッチ例外の記録（`AINotchApplication.reportException` と `NSSetUncaughtExceptionHandler`）。`~/Library/Logs/AINotch/crash.log` |
| `Sources/AINotch/SingleInstance.swift` | 二重起動の防止（先に動いていれば exit 0 で黙って終わる） |
| `hooks/notch-hook.sh` | 各AIのhooksから呼ばれる転送スクリプト（引数で codex / gemini を指定） |
| `hooks/notch_post.py` | POST共通処理（全スクリプトが使用） |
| `hooks/install-hooks.sh` | `~/.claude/settings.json` への登録（バックアップ+冪等） |
| `hooks/notch-run` / `notch-report` | 汎用CLIラッパー / 報告CLI |

## 開発時の注意

1. ビルド・起動は `make run`（バンドル作成→launchdで起動し直す）。`swift run` だと**アクセシビリティ許可がバイナリパスに紐づいて毎回リセットされる**ので、権限テストは必ず `.app` バンドルで行う。
2. 再起動に `pkill` は要らない（`make run` / `make restart` が bootout → bootstrap する）。二重起動ガードがあるので `open` しても増えない。
3. 動作確認はスクリーンショットではなく `curl http://127.0.0.1:43110/debug` と `/sessions` を使う（画面収録権限がないと他アプリのウィンドウ同様スクショに写らない）。
4. hooksスクリプトは**必ず exit 0**（エージェント本体を止めないため）。タイムアウトは2秒厳守。
5. イベントスキーマを変えるときは `SessionStore.handle` と `hooks/notch_post.py` の両方を更新。
6. `~/.codex/config.toml` の notify は Claude Cowork が使用中。**上書き禁止**。
7. このフォルダは独立gitリポジトリ。コミットはこの中で行う。
8. 自動起動の登録先は**実行中の `.app` のパス**なので、`dist/` を移動・削除したら設定し直す（`make app` は同じパスに作り直すので影響なし）。ズレると設定画面が「登録されているパスが違います」と出す。

## 常駐と自動復帰（launchd）

常駐は `~/Library/LaunchAgents/jp.miraistarforce.ainotch.plist` の LaunchAgent が担当する。plistの生成・登録はアプリ側（`LoginItem`）、読み込み直しは `make restart`。

- **`KeepAlive` は `SuccessfulExit: false`**。クラッシュ（異常終了）だけ復帰させ、メニューの「AI Notch を終了」＝正常終了では復帰しない。二重起動ガードの `exit(0)` も同じ理由で復帰しない。
- **アプリ自身が `launchctl bootout` を実行してはいけない**。自分が管理対象なので bootout で殺され、続きの `bootstrap` が走らないまま消える。だから `LoginItem` は読み込み直しをせず、plist の書き換えだけ行う（次のログインから反映）。今すぐ反映したいときは外部＝`make restart` から行う。
- `SMAppService.mainApp`（ただのログイン項目）から移行済み。あれはログイン時に一度起動するだけで、落ちたら**次のログインまで戻ってこない**。2026-08-09にクラッシュしてから5日間気づかず死んだままだった。
- 状態確認は `make agent-status`。`GET /debug` の `supervised` が true なら launchd 管理下（＝落ちても復帰する）、false なら手動起動。
- ログは `~/Library/Logs/AINotch/`（`launchd.err.log` にNSLog、`crash.log` に未キャッチ例外）。
- 診断の自己テストは `open dist/AINotch.app --args --selftest-exception`（意図的に例外を投げて crash.log に残るか確かめる）。

### 2026-08-09のクラッシュ（SwiftUI ScrollView × fixedSize）

`-[NSApplication _crashOnException:]` によるプロセス即死。バックトレースは
CATransactionのcommit → ウィンドウのレイアウトパス → `HostingScrollView` のリサイズ通知 →
SwiftUIがグラフ更新 → **レイアウト中のウィンドウに `setNeedsUpdateConstraints`** → AppKitが例外。

- 原因は**展開パネルの `ScrollView` が `.fixedSize(horizontal: false, vertical: true)` の内側にあったこと**。ScrollViewは「与えられた高さいっぱいに広がる」ビューなので、`fixedSize`（＝中身の理想の高さを教えて）と組み合わせると高さが相互参照になり、レイアウト中の再入が起きる。`TimelineView(.periodic(by: 1.4))` がリストごと1.4秒ごとに作り直すので、開いている間ずっとこのくじを引いていた。
- **ノッチのパネルに ScrollView を置いてはいけない**。代わりに表示量を絞る：`ExpandedPanel.maxVisibleSessions`（4件）、`SessionRow.maxDiffLines`（6行）、詳細カードは**一度に1件だけ**展開（`detailId`）。あふれた分は件数で示す。
- 表示量を増やすときは `GET /debug` の `naturalContentHeight`（中身が必要な高さ）と `maxPanelHeight`（枠）を比べる。`contentClipped: true` なら下が切れており、しかも `contentRect` が枠と一致してホバー判定が壊れる。実測値：4件・詳細1枚・差分6行で約690px、枠は780px。

## イベントAPI（POST /event）

Claude Code hooks形式（`hook_event_name`: SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / PermissionRequest / Notification / Stop / SessionEnd）と汎用形式（`event`: start / status / done / error / remove）の両方を受け付ける。ターミナル特定用に `tty` / `term_program` / `iterm_session_id` / `bundle_id` を付加する。

### 検証で判明した重要な挙動

- **許可プロンプトの検知は PermissionRequest hook を使う**。Notification hook（notification_type: permission_prompt）はVS Code/Cursor拡張環境では発火しないことを実測で確認済み（2026-07）。
- PermissionRequest はダイアログ表示直前に発火し、stdout に何も出力せず exit 0 すれば通常の許可フローに進む（副作用なし）。
- **ノッチの承認はキー送信ではなくhook応答で行う**：hookが `GET /decision?session=..&prompt=..` をポーリングし、決定を `hookSpecificOutput.decision`（behavior: allow は updatedInput 必須、deny は message 必須）として stdout に出力する。決定キーは `session_id:prompt_id`（並行する承認要求を区別するため。payload に `prompt_id` と `permission_suggestions` が含まれることを実測で確認）。
- ユーザーがそのAIの画面を開いたら decision="defer" でhookを解放し、通常のダイアログを出す。
- **AskUserQuestion にも PermissionRequest が飛ぶ**（2026-08-14に実測。`PreToolUse AskUserQuestion` の約1秒後に `PermissionRequest AskUserQuestion`。`tool_input.questions` は同じ中身）。これは「許可」ではないので**承認カードにしてはいけない**（昔は「はい／はい、今後は確認しない／いいえ」が出て、拒否すると質問ごと消えていた）。さらにhookを掴んだままだと**そのAIの画面に質問UIが出ない**ので、`SessionStore.applyQuestion` で質問として扱ったうえで**即座に defer** して画面側に出させる。ノッチは質問文・選択肢（読み取り専用）と「**質問に答える**」＝ジャンプボタンだけを出す。
- **質問への回答はノッチからしない**。選択肢の番号をキー送信すると、同じアプリで動く別のエージェントに数字が入る恐れがあるため（承認と同じ事故）。`NotchActions` に answer は無い。
- **「その画面を見ているか」はウィンドウ単位で判定する**（`SessionStore.isOnScreen`）。Cursor / VS Code は1つのバンドルIDで複数のエージェントが動くため、バンドルIDの一致だけで判定すると**別ウィンドウのエージェントを見ているのに defer してしまい**、ノッチの承認がキー送信にフォールバックして前面の別のClaude Codeに入る（2026-07に実際に発生）。同じアプリで複数セッションが動いているときは、フォーカス中ウィンドウのタイトルにプロジェクト名（cwdの末尾）が含まれるかで判定し、判定できなければ「見ていない」扱いにしてhook経路を保つ。アクセシビリティ未許可のときはキー送信自体できないので従来どおりアプリ単位で判定する。
- **キー送信は送信先を特定できたときだけ行う**（`TerminalControl.jumpThenKeys`）。iTerm=セッションUUID / Terminal=tty / エディタ=AXでタイトル一致のウィンドウが1つだけ、のいずれかで特定でき、かつ送信直前に対象アプリが前面であることを確認してから送る。特定できない場合は送らず「画面を開いて回答してください」と出す。
- **Enterでの承認は相手が一意に決まるときだけ**（`SessionStore.enterApprovalTarget`）。承認待ちが1つ＋hook応答で返せる＋今見ているアプリで別のエージェントが動いていない、を全て満たすときのみCGEventTapを張る（常時張ると他のエージェントに打ったEnterを横取りする）。
- 誤送信の切り分けは `GET /debug` の `accessibilityTrusted` / `frontBundleId` / `frontWindowTitle` / `enterApprovalTarget` を見る。
- デバッグは `GET /events`（受信イベント履歴・最新50件）が最も確実。

### ノッチの当たり判定（ホバー・クリック）

- **ウィンドウ枠（`panelFrame`）と実際の描画範囲（`contentRect`）は一致しない**。展開枠は 680x780 固定だが中身は必要な高さだけ（セッション1件で約174px）。さらに閉じたあとも縮むアニメーションのため**0.36秒は枠が展開サイズのまま残る**。この差分＝透明な余白が当たり判定の罠になる。
- **ホバー判定は必ず `contentRect` で行う**（`NotchWindowController.hoverChanged`）。枠内というだけでホバー扱いにすると、閉じた直後にノッチから離れた位置（例：上端から300px下）へカーソルを戻しただけで再展開し、`collapseSoon` の縮小がキャンセルされて**開きっぱなしで固着する**（2026-08に発生・再現確認済み）。
- **`.onHover` を中身側（枠を広げる `.frame` より前）に付けてはいけない**。展開時の `.transition(.scale)` でホバーが外れ、バーに乗せているのに閉じる／開閉がばたつく。枠全体で `.onContinuousHover` を受けて座標で絞るのが正解。
- **ゴースト中は `hoverChanged` を素通しさせない**（`guard !ghosted`）。`ignoresMouseEvents` の切り替えで発火するホバーを拾うと、半透明状態から勝手に復帰して再展開する。復帰は `ghostTick` の `exitGhost` だけが行う。
- **ゴースト監視タイマーは `.common` ランループモードに入れる**（`RunLoop.main.add(timer, forMode: .common)`）。`Timer.scheduledTimer` の既定モードだと、メニューを開いている間やドラッグ中（`.eventTracking`）に止まる。復帰経路がこのタイマーしかないので、止まると半透明＋クリック透過のまま戻らず「消えて反応しない」ように見える。
- **バーの幅は `sideWidth`（片側70px）で決まる**。物理ノッチ（切り欠き）には描画できないので、左右の実在するメニューバー領域に張り出して見た目を作っている。この張り出しがメニューバー項目を隠すので、広げるときは隠す範囲とのトレードオフになる。
- 切り分けは `GET /debug` の `panelFrame` と `contentRect` を並べて見る（`contentRect` が小さいのが正常。差分が透明な余白）。カーソルを動かしながら `hovering` / `expanded` を追うと誤検知が特定できる。
- **Codex CLI（0.144時点）はClaude互換のhooksに対応**（`~/.codex/hooks.json`、イベント名・ペイロード・hookSpecificOutput応答すべて同形式。対応イベントは SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / PermissionRequest / Stop 等。SessionEnd / Notification は無い）。`config.toml` の notify には触らない。
- **Codexのhookはtrust承認が必要**：登録しただけでは実行されない。`config.toml` の `[hooks.state."<hooks.jsonパス>:<snake_caseイベント名>:<グループ番号>:<ハンドラ番号>"]` に `trusted_hash` を書くと信頼される。ハッシュは「`{"event_name":...,"hooks":[{"async":false,"command":...,"timeout":600(PermissionRequestは設定値),"type":"command"}]}` をキー昇順・圧縮・非ASCII非エスケープでJSON化 → SHA-256」（openai/codex の `version_for_toml`。2026-07に実測一致を確認）。`HookSetup.codexTrustHash` が実装。ズレたらCodex内の `/hooks` で承認し直せる。
- Codexの検証は `codex exec` を使うが、**必ず `</dev/null` を付ける**（stdinが開いたままだと入力待ちで固まる）。hookの状態確認は `codex app-server` に JSON-RPC で `initialize` → `hooks/list` を送ると trustStatus / currentHash が見える。
