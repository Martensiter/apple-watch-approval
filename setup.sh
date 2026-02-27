#!/usr/bin/env bash
# =============================================================================
# Apple Watch Approval セットアップスクリプト
#
# 初回セットアップ:
#   1. Python依存パッケージのインストール
#   2. .env ファイルの生成
#   3. Claude Code の settings.json にフックを登録
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_SETTINGS="$REPO_DIR/.claude/settings.json"
ENV_FILE="$SCRIPT_DIR/.env"
HOOK_PATH="$SCRIPT_DIR/hook.py"

echo "================================================"
echo " Claude Code Apple Watch Approval セットアップ"
echo "================================================"
echo ""

# ---------------------------------------------------------------------------
# Python 仮想環境のセットアップ & 依存パッケージのインストール
# ---------------------------------------------------------------------------
echo "▶ Python 仮想環境をセットアップ中..."
VENV_DIR="$SCRIPT_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    echo "  ✅ 仮想環境を作成しました: $VENV_DIR"
else
    echo "  ℹ️  仮想環境が既に存在します: $VENV_DIR"
fi

echo "▶ Python パッケージをインストール中..."
"$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" --quiet
echo "  ✅ パッケージインストール完了"
echo ""

# ---------------------------------------------------------------------------
# .env ファイルの生成
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    echo "ℹ️  .env ファイルが既に存在します。スキップします。"
    echo "   (変更する場合は $ENV_FILE を編集してください)"
else
    # ユニークなトピック名を生成 (衝突を避けるためランダムサフィックスを追加)
    RANDOM_SUFFIX=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8 2>/dev/null || echo "$(date +%s | tail -c 8)")
    DEFAULT_TOPIC="claude-approval-$RANDOM_SUFFIX"

    echo "▶ ntfy.sh の設定"
    echo "  ntfy.sh のトピック名を入力してください。"
    echo "  (デフォルト: $DEFAULT_TOPIC)"
    echo -n "  トピック名: "
    read -r NTFY_TOPIC_INPUT
    NTFY_TOPIC="${NTFY_TOPIC_INPUT:-$DEFAULT_TOPIC}"

    cat > "$ENV_FILE" << EOF
# Apple Watch Approval 設定

# ntfy.sh トピック名 (iPhone アプリで購読する名前)
NTFY_TOPIC=$NTFY_TOPIC

# ntfy.sh サーバー (デフォルトは公式サーバー)
# セルフホストの場合は変更: https://your-ntfy-server.example.com
NTFY_SERVER=https://ntfy.sh

# 承認待機タイムアウト (秒) - この時間内に応答がなければ拒否扱い
APPROVAL_TIMEOUT=60

# サーバーポート
PORT=8765

# 公開URL (Cloudflare Tunnel などで設定する場合)
# start.sh を使う場合は自動設定されます
# 手動設定: PUBLIC_URL=https://your-tunnel.trycloudflare.com
# PUBLIC_URL=
EOF

    echo "  ✅ .env ファイルを作成しました: $ENV_FILE"
    echo "     トピック名: $NTFY_TOPIC"
fi
echo ""

# ---------------------------------------------------------------------------
# Claude Code settings.json にフックを登録
# ---------------------------------------------------------------------------
echo "▶ Claude Code フックを設定中..."

mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

# 既存の settings.json があるか確認
if [ -f "$CLAUDE_SETTINGS" ]; then
    # Python で既存の設定にフックをマージする
    "$VENV_DIR/bin/python3" << PYEOF
import json
import sys

settings_path = "$CLAUDE_SETTINGS"
hook_path = "$HOOK_PATH"
venv_python = "$VENV_DIR/bin/python3"

try:
    with open(settings_path) as f:
        settings = json.load(f)
except Exception:
    settings = {}

hook_cmd = f"{venv_python} {hook_path}"

# フック設定
new_hook = {
    "type": "command",
    "command": hook_cmd
}

# 既存のフックをチェック
hooks = settings.setdefault("hooks", {})
pre_tool_use = hooks.setdefault("PreToolUse", [])

# 既存のエントリに同じコマンドがないかチェック
already_exists = any(
    any(h.get("command") == hook_cmd for h in entry.get("hooks", []))
    for entry in pre_tool_use
)

if already_exists:
    print("  ℹ️  フックは既に登録されています。")
else:
    pre_tool_use.append({
        "matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [new_hook]
    })
    with open(settings_path, "w") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
    print("  ✅ フックを追加しました")

PYEOF
else
    # 新規作成
    "$VENV_DIR/bin/python3" -c "
import json
settings = {
    'hooks': {
        'PreToolUse': [
            {
                'matcher': 'Bash|Write|Edit|MultiEdit|NotebookEdit',
                'hooks': [
                    {
                        'type': 'command',
                        'command': '$VENV_DIR/bin/python3 $HOOK_PATH'
                    }
                ]
            }
        ]
    }
}
with open('$CLAUDE_SETTINGS', 'w') as f:
    json.dump(settings, f, ensure_ascii=False, indent=2)
print('  ✅ settings.json を作成しました')
"
fi

echo ""

# ---------------------------------------------------------------------------
# 完了メッセージ
# ---------------------------------------------------------------------------
echo "================================================"
echo " セットアップ完了！"
echo "================================================"
echo ""
echo "次のステップ:"
echo ""
echo "  1. 📱 iPhone に ntfy アプリをインストール:"
echo "     https://apps.apple.com/app/ntfy/id1625396347"
echo ""

# トピック名を .env から読み込む
NTFY_TOPIC_DISPLAY=$(grep '^NTFY_TOPIC=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "your-topic")
NTFY_SERVER_DISPLAY=$(grep '^NTFY_SERVER=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "https://ntfy.sh")

echo "  2. 📡 ntfy アプリでトピックを購読:"
echo "     $NTFY_SERVER_DISPLAY/$NTFY_TOPIC_DISPLAY"
echo ""
echo "  3. 🚀 承認サーバーを起動:"
echo "     cd \"$SCRIPT_DIR\" && ./start.sh"
echo ""
echo "  4. 💻 Claude Code を使う:"
echo "     Apple Watch / iPhone で承認通知が届きます！"
echo ""
echo "  ⚙️  アクションボタンが必要な場合:"
echo "     cloudflared をインストールしてから ./start.sh を実行"
echo "     https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
echo ""
