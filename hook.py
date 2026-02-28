#!/usr/bin/env python3
"""
Claude Code PreToolUse Hook - Apple Watch 承認

Claude Code がツールを実行する前に呼ばれるフック。
ローカルの承認サーバーにリクエストを送り、Apple Watch/iPhone での
承認/拒否を待ってから Claude Code に結果を返す。

設定方法: .claude/settings.json の hooks セクションを参照。

終了コード:
  0   - 承認 (Claude Code はツールを実行する)
  2   - 拒否 (Claude Code はツールをブロックする)
"""

import json
import os
import sys
import urllib.request
import urllib.error

SERVER_URL = os.environ.get("APPROVAL_SERVER_URL", "http://localhost:8765")

# 承認が必要なツール
APPROVAL_TOOLS = {
    "Bash",
    "Write",
    "Edit",
    "MultiEdit",
    "NotebookEdit",
}


def call_server(tool_name: str, tool_input: dict) -> bool:
    """
    承認サーバーにリクエストを送り、承認されたかどうかを返す。
    サーバーに接続できない場合は True (フェールオープン) を返す。
    """
    payload = json.dumps(
        {"tool_name": tool_name, "tool_input": tool_input},
        ensure_ascii=False,
    ).encode("utf-8")

    req = urllib.request.Request(
        f"{SERVER_URL}/request",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as e:
        if e.code == 403:
            # 拒否またはタイムアウト
            try:
                body = json.loads(e.read())
                print(f"承認が拒否されました: {body.get('reason', '不明')}", file=sys.stderr)
            except Exception:
                print("承認が拒否されました", file=sys.stderr)
            return False
        # 他のHTTPエラーはフェールオープン
        print(f"[hook] サーバーエラー {e.code}: フェールオープンで続行", file=sys.stderr)
        return True
    except (ConnectionRefusedError, urllib.error.URLError):
        # サーバー未起動の場合はフェールオープン (承認として扱う)
        print(
            "[hook] 承認サーバーに接続できません。起動してください: "
            f"cd apple-watch-approval && python3 server.py",
            file=sys.stderr,
        )
        return True
    except Exception as e:
        print(f"[hook] 予期しないエラー: {e}", file=sys.stderr)
        return True


def main():
    # stdin から Claude Code のツール情報を読み込む
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        sys.exit(0)

    # Cursor (IDE) から呼ばれた場合はスキップ
    # Cursor は環境変数 CURSOR_VERSION をセットし、
    # stdin に cursor_version フィールドを含む
    if os.environ.get("CURSOR_VERSION") or data.get("cursor_version"):
        sys.exit(0)

    tool_name = data.get("tool_name", "")

    # 承認対象外のツールはスキップ
    if tool_name not in APPROVAL_TOOLS:
        sys.exit(0)

    tool_input = data.get("tool_input", {})

    # 承認サーバーに問い合わせる
    approved = call_server(tool_name, tool_input)

    if approved:
        sys.exit(0)  # 承認 → Claude Code はツールを実行する
    else:
        # 拒否 → Claude Code はツールをブロックし、stderr をフィードバックとして使う
        sys.exit(2)


if __name__ == "__main__":
    main()
