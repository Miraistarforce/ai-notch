#!/usr/bin/env python3
"""AI Notch サーバーへイベントをPOSTする共通スクリプト。

環境変数:
  NH_PAYLOAD : hooksから受け取ったJSON（あればこれを基にする）
  NH_EVENT / NH_SID / NH_TITLE / NH_AGENT / NH_STATUS : 汎用イベント用
  NH_TTY / NH_PORT : 付加情報
失敗しても必ず正常終了する（エージェントの動作を止めない）。

PermissionRequest イベントの場合はノッチでの決定をポーリングで待ち、
決定があれば hookSpecificOutput JSON を stdout に出力して
Claude Code に allow/deny を直接返す（ノッチのボタンが本物の承認になる）。
決定がない（defer/タイムアウト/サーバー停止）場合は何も出力せず終了し、
通常の承認ダイアログに進む。
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

# ノッチの決定を待つ最大秒数（hooks側のtimeout=300より短くする）
WAIT_SECONDS = 280


def make_rule(tool, tool_input):
    """「今後は確認しない」用の許可ルールを生成する"""
    if tool == "Bash":
        cmd = str(tool_input.get("command", "")).strip()
        first = cmd.split()[0] if cmd.split() else ""
        if first:
            return f"Bash({first}:*)"
        return "Bash"
    return tool or None


def wait_for_decision(port, d):
    sid = d.get("session_id", "")
    if not sid:
        return
    prompt_id = str(d.get("prompt_id", "") or "")
    url = (
        f"http://127.0.0.1:{port}/decision"
        f"?session={urllib.parse.quote(sid)}&prompt={urllib.parse.quote(prompt_id)}"
    )
    deadline = time.time() + WAIT_SECONDS
    while time.time() < deadline:
        try:
            res = json.loads(urllib.request.urlopen(url, timeout=3).read())
        except Exception:
            return  # サーバー停止 → 通常フローへ
        dec = res.get("decision", "pending")
        if dec == "pending":
            time.sleep(0.5)
            continue
        if dec in ("allow", "allow_always"):
            decision = {
                "behavior": "allow",
                "updatedInput": d.get("tool_input", {}),
            }
            if dec == "allow_always":
                # Claude Code自身が提案するルールがあればそれを優先する
                suggested = d.get("permission_suggestions") or []
                rules = [r for r in suggested if isinstance(r, str)]
                if not rules:
                    rule = make_rule(d.get("tool_name", ""), d.get("tool_input", {}) or {})
                    rules = [rule] if rule else []
                if rules:
                    decision["permissionRules"] = rules
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": decision,
                }
            }))
        elif dec == "deny":
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        "message": "ユーザーがノッチ（AI Notch）から拒否しました。次の指示を待ってください。",
                    },
                }
            }))
        return  # defer やその他 → 何も出力せず通常フローへ


def main():
    raw = os.environ.get("NH_PAYLOAD", "")
    d = {}
    if raw:
        try:
            d = json.loads(raw)
        except Exception:
            d = {}
    if not d:
        d = {
            "event": os.environ.get("NH_EVENT", ""),
            "session_id": os.environ.get("NH_SID", ""),
            "title": os.environ.get("NH_TITLE", ""),
            "agent": os.environ.get("NH_AGENT", ""),
            "status": os.environ.get("NH_STATUS", ""),
            "cwd": os.getcwd(),
        }

    # ターミナル特定用の環境情報を付加
    d["tty"] = os.environ.get("NH_TTY", "")
    d["term_program"] = os.environ.get("TERM_PROGRAM", "")
    d["term_session_id"] = os.environ.get("TERM_SESSION_ID", "")
    d["iterm_session_id"] = os.environ.get("ITERM_SESSION_ID", "")
    d["bundle_id"] = os.environ.get("__CFBundleIdentifier", "")

    port = os.environ.get("NH_PORT", "43110")
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/event",
            data=json.dumps(d).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=2).read()
    except Exception:
        return  # サーバーが動いていなければ即終了

    if d.get("hook_event_name") == "PermissionRequest":
        wait_for_decision(port, d)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
