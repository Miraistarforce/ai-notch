#!/bin/bash
# Codex CLI の notify 設定から呼ばれるスクリプト。
# ~/.codex/config.toml に以下を追記して使う:
#   notify = ["bash", "/path/to/mac-ai-notch/hooks/codex-notify.sh"]
# Codex はターン完了時などにJSONを引数で渡してくる。

DIR="$(cd "$(dirname "$0")" && pwd)"
JSON="$1"

TTY_NAME=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
if [ -n "$TTY_NAME" ] && [ "$TTY_NAME" != "??" ]; then
  NH_TTY="/dev/$TTY_NAME"
else
  NH_TTY=""
fi

NH_CODEX_JSON="$JSON" NH_TTY="$NH_TTY" NH_PORT="${NOTCH_PORT:-43110}" python3 - <<'PY' >/dev/null 2>&1
import json
import os
import urllib.request

raw = os.environ.get("NH_CODEX_JSON", "")
try:
    n = json.loads(raw)
except Exception:
    n = {}

ntype = n.get("type", "")
tty = os.environ.get("NH_TTY", "")
sid = f"codex-{tty or 'main'}"

title = ""
msgs = n.get("input-messages") or n.get("input_messages") or []
if msgs:
    title = str(msgs[0])[:32]
if not title:
    title = "Codex セッション"

if ntype == "agent-turn-complete":
    event, status = "done", "ターン完了 — クリックで移動"
else:
    event, status = "status", "実行中…"

d = {
    "event": event,
    "session_id": sid,
    "title": title,
    "agent": "Codex",
    "status": status,
    "tty": tty,
    "term_program": os.environ.get("TERM_PROGRAM", ""),
    "term_session_id": os.environ.get("TERM_SESSION_ID", ""),
    "iterm_session_id": os.environ.get("ITERM_SESSION_ID", ""),
    "bundle_id": os.environ.get("__CFBundleIdentifier", ""),
}
try:
    req = urllib.request.Request(
        f"http://127.0.0.1:{os.environ.get('NH_PORT', '43110')}/event",
        data=json.dumps(d).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=2).read()
except Exception:
    pass
PY

exit 0
