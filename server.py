#!/usr/bin/env python3
"""
Claude Code Apple Watch Approval Server

Apple Watch (iPhone経由) からClaude Codeの操作を承認/拒否するサーバー。
ntfy.sh でプッシュ通知を送信し、ユーザーが承認/拒否するまで待機する。

フロー:
  Claude Code hook → POST /request → ntfy通知 → Watch/iPhoneでタップ
  → POST /approve or /deny → hookに応答 → Claude Code続行/ブロック
"""

import json
import os
import threading
import uuid
from pathlib import Path

from flask import Flask, jsonify, request

try:
    import requests as http_requests
except ImportError:
    import urllib.request
    import urllib.parse

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

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "claude-approval")
NTFY_SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.sh")
TIMEOUT = int(os.environ.get("APPROVAL_TIMEOUT", "60"))
PORT = int(os.environ.get("PORT", "8765"))

# Cloudflare Tunnel URLを保存するファイル
TUNNEL_URL_FILE = Path(__file__).parent / ".tunnel_url"

# ---------------------------------------------------------------------------
# 承認リクエストの管理
# ---------------------------------------------------------------------------
_pending_events: dict[str, threading.Event] = {}
_pending_results: dict[str, str] = {}  # "approved" | "denied" | "timeout"
_lock = threading.Lock()


def get_public_url() -> str:
    """コールバック用の公開URLを取得する。"""
    # 環境変数を優先
    url = os.environ.get("PUBLIC_URL", "").rstrip("/")
    if url:
        return url
    # ファイルから読み込む (start.sh が書き込む)
    if TUNNEL_URL_FILE.exists():
        return TUNNEL_URL_FILE.read_text().strip().rstrip("/")
    return ""


def format_notification(tool_name: str, tool_input: dict) -> tuple[str, str]:
    """ツール名と入力を通知用のタイトル・メッセージに変換する。"""
    if tool_name == "Bash":
        cmd = tool_input.get("command", "").strip()
        if len(cmd) > 200:
            cmd = cmd[:200] + "…"
        return "Claude: コマンド実行", f"$ {cmd}"

    elif tool_name == "Write":
        path = tool_input.get("file_path", "")
        return "Claude: ファイル作成", f"作成: {path}"

    elif tool_name == "Edit":
        path = tool_input.get("file_path", "")
        return "Claude: ファイル編集", f"編集: {path}"

    elif tool_name == "MultiEdit":
        path = tool_input.get("file_path", "")
        count = len(tool_input.get("edits", []))
        return "Claude: ファイル一括編集", f"編集 ({count}箇所): {path}"

    elif tool_name == "NotebookEdit":
        path = tool_input.get("notebook_path", "")
        return "Claude: ノートブック編集", f"編集: {path}"

    else:
        body = json.dumps(tool_input, ensure_ascii=False)
        if len(body) > 200:
            body = body[:200] + "…"
        return f"Claude: {tool_name}", body


def send_notification(request_id: str, tool_name: str, tool_input: dict) -> bool:
    """ntfy.sh でプッシュ通知を送信する。"""
    title, message = format_notification(tool_name, tool_input)
    public_url = get_public_url()

    headers = {
        "Title": title,
        "Priority": "high",
        "Tags": "robot",
        "Content-Type": "text/plain; charset=utf-8",
    }

    if public_url:
        approve_url = f"{public_url}/approve/{request_id}"
        deny_url = f"{public_url}/deny/{request_id}"
        # ntfy.sh アクションボタン: iPhone/Apple Watch でタップ可能
        headers["Actions"] = (
            f"http, ✅ 承認, {approve_url}, method=POST; "
            f"http, ❌ 拒否, {deny_url}, method=POST"
        )
    else:
        message += "\n\n⚠️ PUBLIC_URL未設定 - ボタン無効"
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
        print(f"[server] 通知送信失敗: {e}")
        return False


# ---------------------------------------------------------------------------
# エンドポイント
# ---------------------------------------------------------------------------

@app.route("/request", methods=["POST"])
def create_request():
    """
    承認リクエストを作成する。ユーザーが応答するまでブロックする。

    Request body (JSON):
        tool_name: str   - ツール名 (例: "Bash")
        tool_input: dict - ツールの入力

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

    print(f"[server] 承認リクエスト [{request_id}] tool={tool_name}")

    # 通知送信
    sent = send_notification(request_id, tool_name, tool_input)
    if not sent:
        print(f"[server] 警告: 通知送信に失敗しました (id={request_id})")

    # ユーザーの応答を待機
    event.wait(timeout=TIMEOUT)

    with _lock:
        result = _pending_results.pop(request_id, "timeout")
        _pending_events.pop(request_id, None)

    print(f"[server] リクエスト [{request_id}] 結果: {result}")

    if result == "approved":
        return jsonify({"approved": True, "request_id": request_id})
    else:
        reason = "拒否されました" if result == "denied" else f"{TIMEOUT}秒でタイムアウト"
        return jsonify({"approved": False, "reason": reason, "request_id": request_id}), 403


@app.route("/approve/<request_id>", methods=["POST"])
def approve(request_id: str):
    """承認する (ntfy.sh アクションボタンから呼ばれる)。"""
    with _lock:
        if request_id not in _pending_events:
            return jsonify({"error": "リクエストが見つかりません"}), 404
        _pending_results[request_id] = "approved"
        _pending_events[request_id].set()

    print(f"[server] 承認: {request_id}")
    return jsonify({"status": "approved", "request_id": request_id})


@app.route("/deny/<request_id>", methods=["POST"])
def deny(request_id: str):
    """拒否する (ntfy.sh アクションボタンから呼ばれる)。"""
    with _lock:
        if request_id not in _pending_events:
            return jsonify({"error": "リクエストが見つかりません"}), 404
        _pending_results[request_id] = "denied"
        _pending_events[request_id].set()

    print(f"[server] 拒否: {request_id}")
    return jsonify({"status": "denied", "request_id": request_id})


@app.route("/health")
def health():
    """サーバーの状態確認。"""
    return jsonify({
        "status": "ok",
        "pending_count": len(_pending_events),
        "ntfy_topic": NTFY_TOPIC,
        "ntfy_server": NTFY_SERVER,
        "public_url": get_public_url() or "(未設定)",
        "timeout_seconds": TIMEOUT,
    })


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print(f"[server] 起動 - ポート: {PORT}")
    print(f"[server] ntfy.sh トピック: {NTFY_TOPIC}")
    public = get_public_url()
    if public:
        print(f"[server] 公開URL: {public}")
    else:
        print("[server] 警告: PUBLIC_URL未設定 - アクションボタンが機能しません")
        print("[server]   → start.sh で自動設定するか、.env に PUBLIC_URL を記載してください")
    print(f"[server] ntfy.sh アプリで購読: {NTFY_SERVER}/{NTFY_TOPIC}")
    print()
    app.run(host="0.0.0.0", port=PORT, debug=False, threaded=True)
