#!/usr/bin/env bash
# =============================================================================
# Apple Watch Approval Server 起動スクリプト
#
# 承認サーバーと Cloudflare Tunnel を起動する。
# Tunnel が起動したら公開URLを取得し、ntfy.sh の通知ボタンに使用する。
#
# 使い方:
#   ./start.sh
#
# 事前設定:
#   .env ファイルに NTFY_TOPIC を設定すること (setup.sh を実行)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TUNNEL_URL_FILE="$SCRIPT_DIR/.tunnel_url"
LOG_DIR="$SCRIPT_DIR/logs"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python3"

mkdir -p "$LOG_DIR"

# .env ファイルを読み込む
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "⚠️  .env ファイルが見つかりません。setup.sh を先に実行してください。"
    echo "   cd \"$SCRIPT_DIR\" && ./setup.sh"
    exit 1
fi

PORT="${PORT:-8765}"
NTFY_TOPIC="${NTFY_TOPIC:-claude-approval}"

echo "================================================"
echo " Claude Code Apple Watch Approval Server"
echo "================================================"
echo " ntfy.sh トピック: $NTFY_TOPIC"
echo " サーバーポート:   $PORT"
echo ""

# 既存の .tunnel_url をクリア
rm -f "$TUNNEL_URL_FILE"

# ---------------------------------------------------------------------------
# Cloudflare Tunnel の起動 (オプション)
# ---------------------------------------------------------------------------
TUNNEL_PID=""

if command -v cloudflared &>/dev/null; then
    echo "▶ Cloudflare Tunnel を起動中..."
    cloudflared tunnel --url "http://localhost:$PORT" --no-autoupdate \
        > "$LOG_DIR/cloudflared.log" 2>&1 &
    TUNNEL_PID=$!

    # トンネルURLの取得を待機 (最大30秒)
    echo -n "  URL取得待機中"
    TUNNEL_URL=""
    for i in $(seq 1 30); do
        sleep 1
        TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' \
            "$LOG_DIR/cloudflared.log" 2>/dev/null | head -1 || true)
        if [ -n "$TUNNEL_URL" ]; then
            break
        fi
        echo -n "."
    done
    echo ""

    if [ -n "$TUNNEL_URL" ]; then
        echo "  ✅ Tunnel URL: $TUNNEL_URL"
        echo "$TUNNEL_URL" > "$TUNNEL_URL_FILE"
        export PUBLIC_URL="$TUNNEL_URL"
    else
        echo "  ⚠️  Tunnel URL を取得できませんでした。"
        echo "     ログ: $LOG_DIR/cloudflared.log"
        echo "     PUBLIC_URL を .env に手動で設定するか、"
        echo "     名前付きトンネルを使用してください。"
    fi
else
    echo "ℹ️  cloudflared が見つかりません。"
    echo "   アクションボタンを使うには Cloudflare Tunnel が必要です。"
    echo "   インストール: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    echo ""
    if [ -n "${PUBLIC_URL:-}" ]; then
        echo "   PUBLIC_URL が設定されています: $PUBLIC_URL"
    fi
fi

# ---------------------------------------------------------------------------
# クリーンアップ
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo "⏹  シャットダウン中..."
    [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
    rm -f "$TUNNEL_URL_FILE"
    echo "   終了しました。"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 承認サーバーの起動
# ---------------------------------------------------------------------------
echo ""
echo "▶ 承認サーバーを起動中 (ポート: $PORT)..."
echo ""
echo "  📱 ntfy.sh アプリで以下のトピックを購読:"
echo "     ${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC"
echo ""
echo "  🔗 ヘルスチェック: http://localhost:$PORT/health"
echo ""
echo "================================================"
echo ""

# サーバー実行
cd "$SCRIPT_DIR"
if [ -f "$VENV_PYTHON" ]; then
    "$VENV_PYTHON" server.py
else
    echo "⚠️  仮想環境が見つかりません。先に setup.sh を実行してください。"
    exit 1
fi
