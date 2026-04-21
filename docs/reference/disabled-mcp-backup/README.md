# 無効化したMCP/プラグインの復活手順

コンテキスト圧縮頻発対策として、2026-04-18にSalesforceデモ作業に不要なMCPサーバーとプラグインをグローバル無効化した。本ドキュメントはその復活手順。

## 無効化した対象

| 対象 | 種別 | 設定ファイル |
|---|---|---|
| `notebooklm-mcp` | MCPサーバー | `~/.claude.json` |
| `aws-serverless@agent-plugins-for-aws` | Plugin | `~/.claude/settings.json` |
| `deploy-on-aws@agent-plugins-for-aws` | Plugin | `~/.claude/settings.json` |

## 復活手順

### AWS系プラグイン（aws-serverless / deploy-on-aws）

`~/.claude/settings.json` の `enabledPlugins` で `false` → `true` に戻す。

```json
"enabledPlugins": {
  "aws-serverless@agent-plugins-for-aws": true,
  "deploy-on-aws@agent-plugins-for-aws": true
}
```

個別に復活させたい場合は片方だけ `true` にする。

### notebooklm-mcp

`~/.claude.json` の `_disabledMcpServers.notebooklm-mcp` を `mcpServers.notebooklm-mcp` に移し戻す。

ワンライナー復活コマンド：

```bash
python3 -c "
import json
path = '/Users/satoshi/.claude.json'
with open(path) as f: d = json.load(f)
if 'notebooklm-mcp' in d.get('_disabledMcpServers', {}):
    d.setdefault('mcpServers', {})['notebooklm-mcp'] = d['_disabledMcpServers'].pop('notebooklm-mcp')
    with open(path, 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
    print('Restored notebooklm-mcp')
"
```

### 適用タイミング

設定変更は**Claude Codeの新規セッションから有効**。既存セッションには反映されない。

## フルバックアップ

このフォルダ内の `.bak-YYYYMMDD-HHMMSS` ファイルが変更前のフルバックアップ。
最悪の場合はこれを元のパスに戻せば完全復元可能。

```bash
# フル復元例（タイムスタンプは実際のファイル名に合わせる）
cp .claude.json.bak-20260418-074450 ~/.claude.json
cp settings.json.bak-20260418-074450 ~/.claude/settings.json
```

## 残課題（ローカル設定では制御不可）

以下はClaude.aiアカウント連携のコネクタ由来のため、ローカルファイルでは制御できない：

- `mcp__claude_ai_Gmail__*`
- `mcp__claude_ai_Google_Calendar__*`
- `mcp__claude_ai_Google_Drive__*`

不要であればClaude.aiの「Connectors」設定画面から切る必要がある。
