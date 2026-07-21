#!/bin/bash
# Claude Code の各hookイベントを AI Notch へ転送する。
# ~/.claude/settings.json の hooks に登録して使う（install-hooks.sh で自動登録）。
# 失敗しても必ず exit 0（Claude Code の動作を止めない）。

DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD=$(cat)

TTY_NAME=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
if [ -n "$TTY_NAME" ] && [ "$TTY_NAME" != "??" ]; then
  NH_TTY="/dev/$TTY_NAME"
else
  NH_TTY=""
fi

NH_PAYLOAD="$PAYLOAD" NH_TTY="$NH_TTY" NH_PORT="${NOTCH_PORT:-43110}" \
  python3 "$DIR/notch_post.py" >/dev/null 2>&1

exit 0
