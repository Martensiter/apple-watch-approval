# Apple Watch Approval for Claude Code

Claude Code（AIエージェント）がファイル編集やコマンド実行をしようとするたびに、Apple Watch / iPhone に通知を送り、承認/拒否できるシステムです。

## 仕組み

```
Claude Code hook → POST /request → ntfy.sh通知 → Watch/iPhoneでタップ
→ POST /approve or /deny → hookに応答 → Claude Code続行/ブロック
```

1. Claude Code が `Bash` / `Write` / `Edit` などのツールを実行しようとする
2. `hook.py` (PreToolUse hook) が起動し、ローカルの承認サーバーにリクエストを送信
3. サーバーが [ntfy.sh](https://ntfy.sh) 経由でプッシュ通知を送信
4. iPhone / Apple Watch に通知が届き、**✅ 承認** / **❌ 拒否** ボタンをタップ
5. Claude Code が続行またはブロックされる

## セットアップ

### 前提条件

- Python 3.8+
- iPhone に [ntfy アプリ](https://apps.apple.com/app/ntfy/id1625396347) をインストール済み
- (オプション) アクションボタンを使う場合は [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) をインストール済み

### 手順

```bash
cd apple-watch-approval

# 1. セットアップ (初回のみ)
./setup.sh

# 2. サーバー起動
./start.sh
```

`setup.sh` が以下を自動実行します：
- Python パッケージのインストール (`flask`, `requests`)
- `.env` ファイルの生成 (ntfy.sh トピック名の設定)
- Claude Code の `~/.claude/settings.json` にフックを登録

### ntfy アプリの設定

1. iPhone に ntfy アプリをインストール
2. セットアップ時に表示されたトピック名を購読
   - 例: `https://ntfy.sh/claude-approval-xxxxxxxx`
3. Apple Watch にも通知が転送されます

## 設定

`.env.example` を `.env` にコピーして編集：

```bash
cp .env.example .env
```

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `NTFY_TOPIC` | `claude-approval` | ntfy.sh トピック名（ユニークな名前を推奨） |
| `NTFY_SERVER` | `https://ntfy.sh` | ntfy.sh サーバー URL |
| `APPROVAL_TIMEOUT` | `60` | 承認待機タイムアウト（秒） |
| `PORT` | `8765` | サーバーポート |
| `PUBLIC_URL` | - | Cloudflare Tunnel など公開URL（アクションボタン用） |

## アクションボタンについて

通知のボタンから直接承認/拒否するには、公開URLが必要です。

`cloudflared` がインストールされていれば `start.sh` が自動的に Cloudflare Tunnel を起動し、公開URLを設定します。

```
インストール: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
```

## 承認が必要なツール

| ツール | 説明 |
|--------|------|
| `Bash` | コマンド実行 |
| `Write` | ファイル作成 |
| `Edit` | ファイル編集 |
| `MultiEdit` | ファイル一括編集 |
| `NotebookEdit` | Jupyter Notebook 編集 |
| `Task` | サブエージェント起動 |

読み取り専用ツール（`Read`, `Glob`, `Grep` など）は承認不要でスキップされます。

## ファイル構成

```
apple-watch-approval/
├── server.py          # Flask 承認サーバー
├── hook.py            # Claude Code PreToolUse フック
├── setup.sh           # 初回セットアップスクリプト
├── start.sh           # サーバー起動スクリプト
├── requirements.txt   # Python 依存パッケージ
└── .env.example       # 環境変数サンプル
```

## ライセンス

MIT
