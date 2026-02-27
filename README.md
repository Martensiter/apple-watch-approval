# Apple Watch Approval for Claude Code

Approve or deny Claude Code's actions from your **Apple Watch or iPhone** before they run.

Every time Claude Code tries to execute a command or edit a file, you get a push notification with **✅ Approve** and **❌ Deny** buttons.

![Notification example](https://ntfy.sh/docs/static/img/ios-detail-demo.png)

## How it works

```
Claude Code  →  PreToolUse hook  →  approval server  →  ntfy.sh push notification
                                                      ←  tap Approve / Deny on Watch
Claude Code continues (or is blocked)
```

1. Claude Code triggers a tool (Bash, Write, Edit, etc.)
2. `hook.py` sends the request to a local Flask server
3. The server pushes a notification via [ntfy.sh](https://ntfy.sh)
4. You tap **Approve** or **Deny** on your iPhone / Apple Watch
5. Claude Code proceeds or is blocked accordingly

## Requirements

- macOS (Apple Silicon or Intel)
- [Claude Code](https://docs.anthropic.com/claude-code) installed
- iPhone with the [ntfy app](https://apps.apple.com/app/ntfy/id1625396347)
- Python 3.8+
- Homebrew (for cloudflared)

## Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/Martensiter/apple-watch-approval/main/install.sh | bash
```

Or clone and run manually:

```bash
git clone https://github.com/Martensiter/apple-watch-approval.git ~/apple-watch-approval
cd ~/apple-watch-approval && bash install.sh
```

The installer will:
1. Create a Python virtual environment and install dependencies
2. Generate a `.env` file with a unique ntfy.sh topic
3. Register a Claude Code PreToolUse hook in `~/.claude/settings.json`
4. Install `cloudflared` via Homebrew (for action buttons)
5. Register a launchd agent so the server **auto-starts on every login**

## After installation

**1. Install the ntfy app on your iPhone**

→ [App Store](https://apps.apple.com/app/ntfy/id1625396347)

**2. Subscribe to your topic**

Open the ntfy app → Add subscription → enter the topic shown at the end of install (e.g. `claude-approval-a1b2c3d4`).  
Make sure **"Use another server"** is **OFF**.

**3. Start Claude Code**

That's it. Notifications will appear on your iPhone and Apple Watch automatically.

## Uninstall

```bash
bash ~/apple-watch-approval/uninstall.sh
rm -rf ~/apple-watch-approval
```

## Configuration

Edit `~/apple-watch-approval/.env` to change settings:

| Variable | Default | Description |
|---|---|---|
| `NTFY_TOPIC` | `claude-approval-xxxx` | Your unique ntfy.sh topic name |
| `NTFY_SERVER` | `https://ntfy.sh` | ntfy server URL (change for self-hosted) |
| `APPROVAL_TIMEOUT` | `60` | Seconds to wait before auto-denying |
| `PORT` | `8765` | Local server port |
| `PUBLIC_URL` | *(auto)* | Set by Cloudflare Tunnel automatically |

After editing `.env`, restart the server:

```bash
launchctl unload ~/Library/LaunchAgents/com.$(whoami).apple-watch-approval.plist
launchctl load  ~/Library/LaunchAgents/com.$(whoami).apple-watch-approval.plist
```

## Which tools require approval?

| Tool | Description |
|---|---|
| `Bash` | Shell command execution |
| `Write` | Create a new file |
| `Edit` / `MultiEdit` | Edit an existing file |
| `NotebookEdit` | Edit a Jupyter notebook |

Read-only tools (`Read`, `Glob`, `Grep`, `WebSearch`, etc.) are **never** sent for approval.

## Troubleshooting

**Notifications arrive but buttons don't work**  
→ The Cloudflare Tunnel may have restarted (URL changes on each restart).  
→ Check the server is running: `curl http://localhost:8765/health`  
→ Re-run `start.sh` to get a fresh Tunnel URL.

**No notifications at all**  
→ Check the log: `tail -f ~/apple-watch-approval/logs/launchd.log`  
→ Make sure your ntfy topic is subscribed **without** "Use another server".

**Server not starting on login**  
→ Run `bash ~/apple-watch-approval/install.sh` again to re-register the launchd agent.

## Project structure

```
apple-watch-approval/
├── server.py       Flask server that manages approval requests
├── hook.py         Claude Code PreToolUse hook
├── start.sh        Starts server + Cloudflare Tunnel
├── install.sh      One-command installer
├── uninstall.sh    Removes everything (except the directory)
├── setup.sh        Manual setup helper (called by install.sh)
├── requirements.txt
└── .env.example
```

## License

MIT
