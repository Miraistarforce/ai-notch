#!/bin/bash
# ~/.claude/settings.json に AI Notch 用のhooksを登録する。
# 既存設定はバックアップしてからマージする。再実行しても重複登録しない。

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/notch-hook.sh"

python3 - "$HOOK" <<'PY'
import json
import os
import shutil
import sys
import time

hook_path = sys.argv[1]
settings_path = os.path.expanduser("~/.claude/settings.json")

settings = {}
if os.path.exists(settings_path):
    backup = f"{settings_path}.bak-{time.strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(settings_path, backup)
    print(f"バックアップ作成: {backup}")
    with open(settings_path) as f:
        settings = json.load(f)

hooks = settings.setdefault("hooks", {})
events = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Notification",
    "Stop",
    "SessionEnd",
]
cmd = f'"{hook_path}"'
added = []
for ev in events:
    matchers = hooks.setdefault(ev, [])
    present = any(
        "notch-hook.sh" in h.get("command", "")
        for m in matchers
        for h in m.get("hooks", [])
    )
    if present:
        continue
    hook_def = {"type": "command", "command": cmd}
    if ev == "PermissionRequest":
        # ノッチでの決定を待つため長めのタイムアウトを明示する
        hook_def["timeout"] = 300
    entry = {"hooks": [hook_def]}
    if ev in ("PreToolUse", "PostToolUse"):
        entry["matcher"] = "*"
    matchers.append(entry)
    added.append(ev)

# 既存インストール分への移行: PermissionRequest に timeout を付与
for m in hooks.get("PermissionRequest", []):
    for h in m.get("hooks", []):
        if "notch-hook.sh" in h.get("command", "") and h.get("timeout") != 300:
            h["timeout"] = 300
            if "PermissionRequest(timeout更新)" not in added:
                added.append("PermissionRequest(timeout更新)")

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(settings, f, ensure_ascii=False, indent=2)
    f.write("\n")

if added:
    print(f"登録したイベント: {', '.join(added)}")
else:
    print("すでに登録済みでした（変更なし）")
print(f"設定ファイル: {settings_path}")
PY

echo "完了。次に起動する Claude Code セッションから AI Notch に状況が表示されます。"
