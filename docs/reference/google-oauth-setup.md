# Local Headless 360 - Google OAuth セットアップ手順

**重要**: 既存の GCP Cloud Functions / Vertex AI 実装には一切影響しない設計です。  
新規 OAuth client（Desktop app）と新規 API key を発行し、`config/tokens/` 配下に分離して配置します。

---

## 1. GCP Console で OAuth client (Desktop app) を発行

**既存の GCP プロジェクトを再利用**します（新しいプロジェクトを作る必要はありません）。

1. GCP Console → APIs & Services → **Credentials**
2. **Create Credentials** → **OAuth client ID**
3. Application type: **Desktop app**
4. Name: `Lh360 Local Agent` （任意の識別名。既存のClient IDと区別できる名前推奨）
5. Create を押下 → JSONファイルをダウンロード
6. ダウンロードしたファイルを以下のパスに配置（リネーム）:
   ```
   /Users/satoshi/claude/bps-salesforce-demo/lh360/config/tokens/google_credentials.json
   ```

### 必要な API の有効化

同じ GCP プロジェクトで以下が **有効になっているか確認**（既存で有効済みの可能性大）:
- Google Calendar API
- Gmail API
- **Distance Matrix API** ← Maps 用

未有効なら APIs & Services → Library から有効化する。

---

## 2. Google Maps API Key 発行

1. APIs & Services → **Credentials** → **Create Credentials** → **API key**
2. 発行された API key を コピー
3. **API key の制限（推奨）**:
   - Application restrictions: **IP addresses** → 自宅 / 職場の IP を登録
   - API restrictions: **Distance Matrix API** のみに制限
4. `.env` に設定:
   ```env
   GOOGLE_MAPS_API_KEY=<発行されたキー>
   ```

---

## 3. 初回 OAuth 同意（ブラウザで1回だけ）

```bash
cd /Users/satoshi/claude/bps-salesforce-demo/lh360
uv run python -m mcp_clients.google_auth
```

- ブラウザが立ち上がり、Google アカウント選択 → 権限同意（Calendar + Gmail Compose）
- 成功すると `config/tokens/google_token.json` に refresh_token が保存される
- 以降は自動更新（再認証不要）

### OAuth 同意画面（Consent Screen）が未設定の場合

- **User Type: External** で作成
- Test users に自分の Gmail (`satoshi.nagahara@gmail.com`) を追加
- Scopes は unrestricted のまま（Desktop app なので審査不要）

---

## 4. スモークテスト

```bash
uv run python -m tests.test_google_mcp_smoke
```

期待結果:
- 6 tools 登録確認
- get_user_profile → 長原 聡 + 曜日別勤務パターン
- calendar_list_events → 今日〜3日後の予定
- calendar_check_availability → 明日の10-11時 / 14-15時の busy 判定
- maps_travel_time → 丸の内⇔三軒茶屋の transit 所要時間

---

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `credentials.json not found` | ダウンロード先のパスが違う | `config/tokens/google_credentials.json` に配置 |
| OAuth 同意画面で "Error 403: access_denied" | Test user 未登録 | Consent Screen → Test users に自分を追加 |
| Maps `REQUEST_DENIED` | API key 未設定 or Distance Matrix API 未有効化 | 両方を設定 |
| Gmail scope 足りないエラー | scope 変更時は `google_token.json` を削除して再同意 | `rm config/tokens/google_token.json` → 再実行 |

---

## 既存 GCP 実装との分離保証

| リソース | 既存（/docs/in-progress/gcp-demo-build-log.md） | この Lh360 |
|---|---|---|
| OAuth Client | （なし / service account 主体） | 新規 Desktop OAuth client |
| API Key | Cloud Functions 内部で使用 | `GOOGLE_MAPS_API_KEY` 別名で別用途 |
| 有効化する API | Vertex AI, Cloud Storage 等 | Calendar / Gmail / Distance Matrix（追加のみ） |
| token 保存先 | Cloud Functions ランタイム内 | ローカル `config/tokens/`（gitignore済） |

**追加のみ、既存変更ゼロ**。既存 CF は停止せずに動作継続する。
