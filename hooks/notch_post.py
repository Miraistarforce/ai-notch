#!/usr/bin/env python3
"""AI Notch サーバーへイベントをPOSTする共通スクリプト。

環境変数:
  NH_PAYLOAD : hooksから受け取ったJSON（あればこれを基にする）
  NH_EVENT / NH_SID / NH_TITLE / NH_AGENT / NH_STATUS : 汎用イベント用
  NH_TTY / NH_PORT : 付加情報
失敗しても必ず正常終了する（エージェントの動作を止めない）。
"""
import json
import os
import sys
import urllib.request


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
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
