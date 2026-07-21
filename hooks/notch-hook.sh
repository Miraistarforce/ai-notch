#!/bin/bash
# 各AI CLIのhookイベントを AI Notch へ転送する。
# 引数でエージェント種別を指定できる（省略時は Claude Code）:
#   notch-hook.sh          → Claude Code（~/.claude/settings.json に登録）
#   notch-hook.sh codex    → Codex/ChatGPT（~/.codex/hooks.json に登録）
#   notch-hook.sh gemini   → Gemini CLI（~/.gemini/settings.json に登録）
# 登録はアプリのメニューバー（Clawdアイコン→設定）から行える。
# 失敗しても必ず exit 0（エージェント本体を止めない）。

DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD=$(cat)

case "$1" in
  codex)  NH_AGENT="Codex" ;;
  gemini) NH_AGENT="Gemini" ;;
  *)      NH_AGENT="" ;;
esac

TTY_NAME=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
if [ -n "$TTY_NAME" ] && [ "$TTY_NAME" != "??" ]; then
  NH_TTY="/dev/$TTY_NAME"
else
  NH_TTY=""
fi

# stdoutはCLI本体が読む（PermissionRequestの許可/拒否応答に使う）ため塞がない
NH_PAYLOAD="$PAYLOAD" NH_AGENT="$NH_AGENT" NH_TTY="$NH_TTY" NH_PORT="${NOTCH_PORT:-43110}" \
  python3 "$DIR/notch_post.py" 2>/dev/null

exit 0
