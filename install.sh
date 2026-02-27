#!/usr/bin/env bash
# =============================================================================
# Apple Watch Approval for Claude Code - Installer
#
# Downloads the repo, sets up Python venv, configures Claude Code hooks,
# and registers a launchd agent for auto-start on login (macOS only).
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/Martensiter/apple-watch-approval/main/install.sh | bash
#
# Or clone and run:
#   git clone https://github.com/Martensiter/apple-watch-approval.git
#   cd apple-watch-approval && bash install.sh
# =============================================================================

set -euo pipefail

REPO_URL="https://github.com/Martensiter/apple-watch-approval.git"
INSTALL_DIR="$HOME/apple-watch-approval"
PLIST_LABEL="com.$(whoami).apple-watch-approval"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}▶${NC} $*"; }
warning() { echo -e "${YELLOW}⚠️ ${NC} $*"; }
error()   { echo -e "${RED}✖${NC} $*" >&2; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Apple Watch Approval for Claude Code           ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# 1. macOS check
# ---------------------------------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
    error "This installer supports macOS only."
fi

# ---------------------------------------------------------------------------
# 2. Clone or update repo
# ---------------------------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing installation at $INSTALL_DIR ..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    # If running via pipe (curl | bash), clone the repo
    if [ ! -f "${BASH_SOURCE[0]:-/dev/null}" ] || [ "${BASH_SOURCE[0]}" = "/dev/stdin" ]; then
        info "Cloning repository to $INSTALL_DIR ..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    else
        # Running from inside the repo — just use current directory
        INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        info "Using existing directory: $INSTALL_DIR"
    fi
fi

cd "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# 3. Python venv + packages
# ---------------------------------------------------------------------------
info "Setting up Python virtual environment..."
VENV_DIR="$INSTALL_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt" --quiet --upgrade
echo "  ✅ Python packages installed"

# ---------------------------------------------------------------------------
# 4. .env file
# ---------------------------------------------------------------------------
ENV_FILE="$INSTALL_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    info ".env already exists — skipping (edit $ENV_FILE to change settings)"
else
    RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 8 || date +%s | tail -c 8)
    DEFAULT_TOPIC="claude-approval-$RANDOM_SUFFIX"

    info "ntfy.sh topic setup"
    echo "  Enter a topic name for ntfy.sh notifications."
    echo "  (default: $DEFAULT_TOPIC)"
    echo -n "  Topic name: "
    read -r NTFY_TOPIC_INPUT
    NTFY_TOPIC="${NTFY_TOPIC_INPUT:-$DEFAULT_TOPIC}"

    cat > "$ENV_FILE" << EOF
# Apple Watch Approval - configuration

NTFY_TOPIC=$NTFY_TOPIC
NTFY_SERVER=https://ntfy.sh
APPROVAL_TIMEOUT=60
PORT=8765

# PUBLIC_URL is set automatically by start.sh via Cloudflare Tunnel.
# Uncomment to set manually:
# PUBLIC_URL=https://your-tunnel.trycloudflare.com
EOF
    echo "  ✅ Created .env (topic: $NTFY_TOPIC)"
fi

# ---------------------------------------------------------------------------
# 5. Claude Code hook (global ~/.claude/settings.json)
# ---------------------------------------------------------------------------
info "Registering Claude Code hook..."
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
HOOK_CMD="$VENV_DIR/bin/python3 $INSTALL_DIR/hook.py"

"$VENV_DIR/bin/python3" - <<PYEOF
import json, os, sys

path = "$CLAUDE_SETTINGS"
hook_cmd = "$HOOK_CMD"

try:
    with open(path) as f:
        settings = json.load(f)
except Exception:
    settings = {}

hooks = settings.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])

exists = any(
    any(h.get("command") == hook_cmd for h in e.get("hooks", []))
    for e in pre
)

if exists:
    print("  ℹ️  Hook already registered")
else:
    pre.append({
        "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [{"type": "command", "command": hook_cmd}]
    })
    with open(path, "w") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
    print("  ✅ Hook registered in ~/.claude/settings.json")
PYEOF

# ---------------------------------------------------------------------------
# 6. cloudflared (optional, needed for action buttons)
# ---------------------------------------------------------------------------
if ! command -v cloudflared &>/dev/null; then
    info "Installing cloudflared (needed for Approve/Deny buttons)..."
    if command -v brew &>/dev/null; then
        brew install cloudflare/cloudflare/cloudflared --quiet
        echo "  ✅ cloudflared installed"
    else
        warning "Homebrew not found. Install cloudflared manually:"
        echo "    https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    fi
else
    echo "  ✅ cloudflared already installed ($(cloudflared --version 2>&1 | head -1))"
fi

# ---------------------------------------------------------------------------
# 7. launchd agent (auto-start on login)
# ---------------------------------------------------------------------------
info "Registering launchd agent for auto-start on login..."
mkdir -p "$(dirname "$PLIST_PATH")"
mkdir -p "$INSTALL_DIR/logs"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/start.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$INSTALL_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/logs/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/logs/launchd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF

# Unload existing agent if present, then reload
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "  ✅ launchd agent registered (auto-starts on login)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
NTFY_TOPIC_DISPLAY=$(grep '^NTFY_TOPIC=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "your-topic")
NTFY_SERVER_DISPLAY=$(grep '^NTFY_SERVER=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "https://ntfy.sh")

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Installation complete!                         ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Next steps:"
echo ""
echo "  1. 📱 Install the ntfy app on your iPhone:"
echo "     https://apps.apple.com/app/ntfy/id1625396347"
echo ""
echo "  2. 📡 Subscribe to your topic in the ntfy app:"
echo "     $NTFY_SERVER_DISPLAY/$NTFY_TOPIC_DISPLAY"
echo ""
echo "  3. ✅ The approval server is already running."
echo "     It will auto-start on every login."
echo ""
echo "  4. 💻 Start Claude Code — you'll get approval"
echo "     notifications on your iPhone / Apple Watch!"
echo ""
echo "  Logs: $INSTALL_DIR/logs/launchd.log"
echo "  Uninstall: bash $INSTALL_DIR/uninstall.sh"
echo ""
