#!/usr/bin/env bash
# =============================================================================
# Apple Watch Approval for Claude Code - Uninstaller
# =============================================================================

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_LABEL="com.$(whoami).apple-watch-approval"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="$INSTALL_DIR/.venv/bin/python3 $INSTALL_DIR/hook.py"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Apple Watch Approval - Uninstall               ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# 1. Stop and remove launchd agent
if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "✅ launchd agent removed"
else
    echo "ℹ️  launchd agent not found (already removed?)"
fi

# 2. Kill running server / tunnel
pkill -f "python3.*server.py" 2>/dev/null && echo "✅ Server process stopped" || true
pkill -f "cloudflared" 2>/dev/null && echo "✅ Cloudflare Tunnel stopped" || true

# 3. Remove Claude Code hook from ~/.claude/settings.json
if [ -f "$CLAUDE_SETTINGS" ]; then
    python3 - <<PYEOF
import json

path = "$CLAUDE_SETTINGS"
hook_cmd = "$HOOK_CMD"

try:
    with open(path) as f:
        settings = json.load(f)
except Exception:
    print("ℹ️  Could not read settings.json")
    exit(0)

pre = settings.get("hooks", {}).get("PreToolUse", [])
new_pre = [
    e for e in pre
    if not any(h.get("command") == hook_cmd for h in e.get("hooks", []))
]

if len(new_pre) == len(pre):
    print("ℹ️  Hook not found in settings.json (already removed?)")
else:
    settings["hooks"]["PreToolUse"] = new_pre
    if not settings["hooks"]["PreToolUse"]:
        del settings["hooks"]["PreToolUse"]
    if not settings.get("hooks"):
        settings.pop("hooks", None)
    with open(path, "w") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
    print("✅ Claude Code hook removed from ~/.claude/settings.json")
PYEOF
fi

echo ""
echo "Done. The install directory was NOT deleted."
echo "To fully remove it, run:  rm -rf \"$INSTALL_DIR\""
echo ""
