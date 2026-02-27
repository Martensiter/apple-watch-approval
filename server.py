#!/usr/bin/env python3
"""
Claude Code Apple Watch Approval Server

Sends push notifications via ntfy.sh when Claude Code wants to run a tool,
and waits for the user to approve or deny from iPhone / Apple Watch.

Flow:
  Claude Code hook → POST /request → ntfy notification → tap on Watch/iPhone
  → POST /approve or /deny → response to hook → Claude Code continues/blocked
"""

import base64
import json
import os
import sys
import threading
import uuid
from pathlib import Path

from flask import Flask, jsonify, request

try:
    import requests as http_requests
except ImportError:
    import urllib.request

    class _FallbackRequests:
        def post(self, url, data=None, headers=None, timeout=10):
            req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST")
            try:
                resp = urllib.request.urlopen(req, timeout=timeout)
                return type("R", (), {"status_code": resp.status})()
            except Exception:
                return type("R", (), {"status_code": 500})()

    http_requests = _FallbackRequests()

app = Flask(__name__)
app.config["JSON_ENSURE_ASCII"] = False

# Flush stdout immediately so logs appear in real time
print = __builtins__["print"] if isinstance(__builtins__, dict) else __import__("builtins").print
import functools
print = functools.partial(print, flush=True)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "claude-approval")
NTFY_SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.sh")
TIMEOUT = int(os.environ.get("APPROVAL_TIMEOUT", "60"))
PORT = int(os.environ.get("PORT", "8765"))

TUNNEL_URL_FILE = Path(__file__).parent / ".tunnel_url"

# ---------------------------------------------------------------------------
# Pending request management
# ---------------------------------------------------------------------------
_pending_events: dict[str, threading.Event] = {}
_pending_results: dict[str, str] = {}  # "approved" | "denied" | "timeout"
_lock = threading.Lock()


def get_public_url() -> str:
    """Return the public callback URL (env var takes precedence over file)."""
    url = os.environ.get("PUBLIC_URL", "").rstrip("/")
    if url:
        return url
    if TUNNEL_URL_FILE.exists():
        return TUNNEL_URL_FILE.read_text().strip().rstrip("/")
    return ""


def _encode_header(value: str) -> str:
    """Encode non-ASCII header values as RFC 2047 base64."""
    try:
        value.encode("latin-1")
        return value
    except (UnicodeEncodeError, UnicodeDecodeError):
        encoded = base64.b64encode(value.encode("utf-8")).decode()
        return f"=?utf-8?b?{encoded}?="


def format_notification(tool_name: str, tool_input: dict) -> tuple[str, str]:
    """Convert tool name/input into a notification title and body."""
    if tool_name == "Bash":
        cmd = tool_input.get("command", "").strip()
        if len(cmd) > 200:
            cmd = cmd[:200] + "…"
        return "Claude: Run command", f"$ {cmd}"

    elif tool_name == "Write":
        path = tool_input.get("file_path", "")
        return "Claude: Create file", f"Create: {path}"

    elif tool_name == "Edit":
        path = tool_input.get("file_path", "")
        return "Claude: Edit file", f"Edit: {path}"

    elif tool_name == "MultiEdit":
        path = tool_input.get("file_path", "")
        count = len(tool_input.get("edits", []))
        return "Claude: Edit file", f"Edit ({count} changes): {path}"

    elif tool_name == "NotebookEdit":
        path = tool_input.get("notebook_path", "")
        return "Claude: Edit notebook", f"Edit: {path}"

    else:
        body = json.dumps(tool_input, ensure_ascii=False)
        if len(body) > 200:
            body = body[:200] + "…"
        return f"Claude: {tool_name}", body


def send_notification(request_id: str, tool_name: str, tool_input: dict) -> bool:
    """Send a push notification via ntfy.sh."""
    title, message = format_notification(tool_name, tool_input)
    public_url = get_public_url()

    headers = {
        "Title": _encode_header(title),
        "Priority": "high",
        "Tags": "robot",
        "Content-Type": "text/plain; charset=utf-8",
    }

    if public_url:
        approve_url = f"{public_url}/approve/{request_id}"
        deny_url = f"{public_url}/deny/{request_id}"
        headers["Actions"] = (
            f"http, ✅ Approve, {approve_url}, method=POST; "
            f"http, ❌ Deny, {deny_url}, method=POST"
        )
    else:
        message += "\n\n⚠️ Action buttons unavailable (PUBLIC_URL not set)"
        headers["Tags"] = "robot,warning"

    try:
        resp = http_requests.post(
            f"{NTFY_SERVER}/{NTFY_TOPIC}",
            data=message.encode("utf-8"),
            headers=headers,
            timeout=10,
        )
        return getattr(resp, "status_code", 0) == 200
    except Exception as e:
        print(f"[server] Failed to send notification: {e}")
        return False


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.route("/request", methods=["POST"])
def create_request():
    """
    Create an approval request and block until the user responds.

    Request body (JSON):
        tool_name: str   - Tool name (e.g. "Bash")
        tool_input: dict - Tool input parameters

    Response:
        200: {"approved": true}
        403: {"approved": false, "reason": "..."}
    """
    data = request.get_json(silent=True) or {}
    tool_name = data.get("tool_name", "Unknown")
    tool_input = data.get("tool_input", {})

    request_id = str(uuid.uuid4())[:8]
    event = threading.Event()

    with _lock:
        _pending_events[request_id] = event
        _pending_results[request_id] = "timeout"

    print(f"[server] Approval request [{request_id}] tool={tool_name}")

    sent = send_notification(request_id, tool_name, tool_input)
    if not sent:
        print(f"[server] Warning: failed to send notification (id={request_id})")

    event.wait(timeout=TIMEOUT)

    with _lock:
        result = _pending_results.pop(request_id, "timeout")
        _pending_events.pop(request_id, None)

    print(f"[server] Request [{request_id}] result: {result}")

    if result == "approved":
        return jsonify({"approved": True, "request_id": request_id})
    else:
        reason = "Denied by user" if result == "denied" else f"Timed out after {TIMEOUT}s"
        return jsonify({"approved": False, "reason": reason, "request_id": request_id}), 403


@app.route("/approve/<request_id>", methods=["POST"])
def approve(request_id: str):
    """Approve a pending request (called by ntfy.sh action button)."""
    with _lock:
        if request_id not in _pending_events:
            return jsonify({"error": "Request not found"}), 404
        _pending_results[request_id] = "approved"
        _pending_events[request_id].set()

    print(f"[server] Approved: {request_id}")
    return jsonify({"status": "approved", "request_id": request_id})


@app.route("/deny/<request_id>", methods=["POST"])
def deny(request_id: str):
    """Deny a pending request (called by ntfy.sh action button)."""
    with _lock:
        if request_id not in _pending_events:
            return jsonify({"error": "Request not found"}), 404
        _pending_results[request_id] = "denied"
        _pending_events[request_id].set()

    print(f"[server] Denied: {request_id}")
    return jsonify({"status": "denied", "request_id": request_id})


@app.route("/health")
def health():
    """Health check endpoint."""
    return jsonify({
        "status": "ok",
        "pending_count": len(_pending_events),
        "ntfy_topic": NTFY_TOPIC,
        "ntfy_server": NTFY_SERVER,
        "public_url": get_public_url() or "(not set)",
        "timeout_seconds": TIMEOUT,
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print(f"[server] Starting on port {PORT}")
    print(f"[server] ntfy.sh topic: {NTFY_TOPIC}")
    public = get_public_url()
    if public:
        print(f"[server] Public URL: {public}")
    else:
        print("[server] Warning: PUBLIC_URL not set - action buttons will be disabled")
        print("[server]   → Run start.sh to set it automatically via Cloudflare Tunnel")
    print(f"[server] Subscribe in ntfy app: {NTFY_SERVER}/{NTFY_TOPIC}")
    print()
    app.run(host="0.0.0.0", port=PORT, debug=False, threaded=True)
