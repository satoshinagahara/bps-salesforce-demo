# GCP Product Engineering Agent — RAG 切替・切り戻し ランブック

> **対象**: Cloud Functions `generate-design-suggestion` (ageless-lamp-251200 / asia-northeast1)
> **関連**: [gcp-rag-migration-design.md](./gcp-rag-migration-design.md)
> **前提**: Phase 1-3 完了済み（BQインデックス構築済み・RAG版エンドポイント稼働中）

---

## 1. 方針と範囲

### 1.1 切替方式

**環境変数 `USE_RAG=true` による GCP側単独切替**を採用する。理由：

- LWC / Apex / IoT `/trigger` HTML / カスタムオブジェクトは**一切触らない**
- 切替単位が1カ所（Cloud Functions 環境変数）なので切り戻しが速い
- Salesforce 側デプロイ不要 → トラフィック瞬時切替が可能

### 1.2 切替の仕組み

`main.py` の2つのハンドラ内で環境変数を確認し、`true` なら RAG版エージェントに委譲する：

```python
# _handle_design_suggestion_agent 内
if os.environ.get("USE_RAG", "false").lower() == "true":
    from product_engineering_agent_rag import run_agent_rag
    result = run_agent_rag(...)
else:
    from product_engineering_agent import run_agent
    result = run_agent(...)
```

この分岐コードは **本ランブック実施前に main.py へ実装・デプロイする必要がある**（別途タスク）。
並走エンドポイント `/design-suggestion-agent-rag` / `/equipment-alert-rag` は切替後も残し、直接叩きたいケース用に維持する。

### 1.3 影響範囲マトリクス

| 対象 | 切替時に変更? | 切り戻し時に変更? |
|---|---|---|
| Cloud Functions 環境変数 `USE_RAG` | ✅ `true` に変更 | ✅ `false` に戻す |
| Cloud Functions コード | ❌ 不要（分岐コード導入後） | ❌ 不要 |
| LWC `designSuggestionGcp` | ❌ 不要 | ❌ 不要 |
| Apex `DesignSuggestionGcpController` | ❌ 不要 | ❌ 不要 |
| IoT `/trigger` HTMLページ | ❌ 不要 | ❌ 不要 |
| Salesforce カスタムオブジェクト | ❌ 不要 | ❌ 不要 |

### 1.4 UIラベル整合性に関する注意

切替後、以下の進捗ステップラベルは**処理内容と一致しなくなる**（軽微な不整合）：

- LWC designSuggestionGcp: step 2「Cloud Storage から仕様書PDF・図面を取得」→ 実際は BigQuery Vector Search
- IoT `/trigger`: step 3「Cloud Storage から仕様書PDF・図面PNGを取得中」→ 同上

**この不整合はデモ説明時に口頭で補足するか、別途ラベル更新コミットを打つかの判断**。処理完了後の「ツール呼出履歴」は tool 名をそのまま表示するため、そちらで `retrieve_spec_chunks` が見える。

---

## 2. 切替前の前提チェック

以下を**全て満たしていること**を作業開始前に確認する。

### 2.1 GCP 側

```bash
# [1] BQ インデックスが存在し、22行投入済み
bq query --use_legacy_sql=false --format=pretty --project_id=ageless-lamp-251200 \
  "SELECT doc_type, COUNT(*) AS n FROM \`bps_rag.chunks\` GROUP BY doc_type"
# 期待: figure=2, spec=20

# [2] サービスアカウントが BigQuery 権限を持つ
gcloud projects get-iam-policy ageless-lamp-251200 \
  --flatten="bindings[].members" \
  --format="table(bindings.role)" \
  --filter="bindings.members:bps-demo-sa@ageless-lamp-251200.iam.gserviceaccount.com" \
  | grep -E "bigquery\.(jobUser|dataViewer)"
# 期待: 両方のロール表示

# [3] Cloud Functions が ACTIVE
gcloud functions describe generate-design-suggestion \
  --region=asia-northeast1 --project=ageless-lamp-251200 \
  --format="value(state,updateTime)"
# 期待: ACTIVE

# [4] RAG エンドポイントが疎通する（baseline を触らない直接叩きテスト）
curl -s -X POST "https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/design-suggestion-agent-rag" \
  -H "Content-Type: application/json" \
  -d '{"initiativeId":"a3EIe000000AulqMAC"}' \
  --max-time 180 | python3 -c "import sys,json; d=json.load(sys.stdin); print('status=', d.get('status'), 'iterations=', d.get('iterations'))"
# 期待: status=completed, iterations<=10
```

### 2.2 コード側

- [ ] `main.py` に `USE_RAG` 分岐コードが実装済み（_handle_design_suggestion_agent / _handle_equipment_alert 両方）
- [ ] 分岐コードが main ブランチに commit & push 済み（切り戻しは環境変数操作のみで完結させるため、コード上はデフォルトで baseline に戻る状態にしておく）
- [ ] 本ランブック直前の Cloud Functions revision を控えておく（`gcloud functions describe` の serviceConfig.revision）

### 2.3 Budget

- [ ] Budget alert `bps-demo-monthly-3000jpy` が有効
- [ ] 当月の現在消費額が ¥2,000 未満（切替で追加¥数十/月想定だが念のため）

---

## 3. 切替手順（baseline → RAG）

### Step 1. 作業開始ログの残置

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [cutover-start] baseline → RAG" \
  >> ~/claude/bps-salesforce-demo/docs/in-progress/gcp-rag-cutover-runbook.log
```

### Step 2. 環境変数の切替

**オプションA: `.env.yaml` 経由（推奨。履歴がgitに残る）**

```bash
# .env.yaml に USE_RAG: "true" を追記してから再デプロイ
cd ~/claude/bps-salesforce-demo/gcp/generate-design-suggestion
# .env.yaml の末尾に "USE_RAG: \"true\"" を追記する（手動 or sedで）

gcloud functions deploy generate-design-suggestion \
  --gen2 --runtime=python312 --region=asia-northeast1 --source=. \
  --entry-point=generate_design_suggestion --trigger-http --allow-unauthenticated \
  --memory=1Gi --timeout=300 --min-instances=1 \
  --env-vars-file=.env.yaml \
  --service-account=bps-demo-sa@ageless-lamp-251200.iam.gserviceaccount.com \
  --project=ageless-lamp-251200
# 所要: 2〜3分
```

**オプションB: `--update-env-vars` で1行差替（高速、gitには残らない）**

```bash
gcloud functions deploy generate-design-suggestion \
  --gen2 --region=asia-northeast1 \
  --update-env-vars=USE_RAG=true \
  --project=ageless-lamp-251200
# 所要: 1〜2分
```

### Step 3. 反映確認

```bash
gcloud functions describe generate-design-suggestion \
  --region=asia-northeast1 --project=ageless-lamp-251200 \
  --format="value(serviceConfig.environmentVariables.USE_RAG,serviceConfig.revision,state)"
# 期待: true  generate-design-suggestion-00033-xxx  ACTIVE
```

### Step 4. 切替後スモークテスト

```bash
# [A] シナリオ1: LWC経由相当（Apex → /design-suggestion-agent）を叩く
curl -s -X POST "https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/design-suggestion-agent" \
  -H "Content-Type: application/json" \
  -d '{"initiativeId":"a3EIe000000AulqMAC"}' \
  --max-time 180 | python3 -c "
import sys,json
d=json.load(sys.stdin)
tools=[t.get('tool') for t in d.get('toolHistory',[])]
print('status=',d.get('status'),'iterations=',d.get('iterations'))
print('processedBy=',d.get('processedBy'))
print('retrieve called?', 'retrieve_spec_chunks' in tools)
"
# 期待:
#   status=completed
#   processedBy=Vertex AI gemini-2.5-flash (RAG Agent)   ← ★RAG版に切替わったことの証拠
#   retrieve called? True
```

```bash
# [B] シナリオ2: IoTシミュレーター経由相当を叩く
curl -s -X POST "https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/equipment-alert" \
  -H "Content-Type: application/json" \
  -d '{"assetId":"02iIe00000165UeIAI","sensorType":"セル温度","value":47.5,"threshold":45.0,"location":"Bangkok Plant B"}' \
  --max-time 180 | python3 -c "
import sys,json
d=json.load(sys.stdin)
tools=[t.get('tool') for t in d.get('toolHistory',[])]
print('status=',d.get('status'),'alertId=',d.get('alertId'))
print('retrieve called?', 'retrieve_spec_chunks' in tools)
"
# 期待: status=completed, retrieve called? True
```

### Step 5. Salesforce側のUIでエンドツーエンド確認

1. Salesforce の Product_Initiative__c レコード `a3EIe000000AulqMAC` を開く
2. 「製品改善提案 by GCP」タブから実行ボタンを押す
3. 進捗演出完了後、DesignSuggestion__c が作成されることを確認
4. Asset レコード `02iIe00000165UeIAI` を開き、「設備アラート by GCP」タブから実行
5. Equipment_Alert__c が作成されることを確認

**重要**: LWCの進捗ステップラベル「Cloud Storage から…」は処理内容と一致しなくなる点を認識の上で観察する。tool_history エリアには `retrieve_spec_chunks` が表示されるはず。

### Step 6. Dashboard で可視化確認

[https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/dashboard](https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/dashboard) を開く。

- 最新行のMode列に `RAG` バッジが付いている
- Variant フィルタで「RAG のみ」を選んで切替後の実行だけが見える
- Today / Baseline · RAG の rag カウントが増えている

### Step 7. 作業完了ログ

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [cutover-done] baseline → RAG success" \
  >> ~/claude/bps-salesforce-demo/docs/in-progress/gcp-rag-cutover-runbook.log
```

---

## 4. 切り戻し手順（RAG → baseline）

### 判断基準

以下のいずれかに該当する場合は速やかに切り戻す：

- LWC / IoT trigger から叩いても `status=incomplete` / エラーが連続する
- retrieve_spec_chunks がタイムアウト / 5xx を返す
- Budget アラート（50% = ¥1,500）が発火
- デモ直前で挙動不安

### Step 1. 作業開始ログ

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [rollback-start] RAG → baseline" \
  >> ~/claude/bps-salesforce-demo/docs/in-progress/gcp-rag-cutover-runbook.log
```

### Step 2. 環境変数を戻す

**オプションA（.env.yaml利用時）**: `.env.yaml` から `USE_RAG: "true"` 行を削除 or `"false"` に変更し、再デプロイ

```bash
cd ~/claude/bps-salesforce-demo/gcp/generate-design-suggestion
# .env.yaml 編集後:
gcloud functions deploy generate-design-suggestion \
  --gen2 --runtime=python312 --region=asia-northeast1 --source=. \
  --entry-point=generate_design_suggestion --trigger-http --allow-unauthenticated \
  --memory=1Gi --timeout=300 --min-instances=1 \
  --env-vars-file=.env.yaml \
  --service-account=bps-demo-sa@ageless-lamp-251200.iam.gserviceaccount.com \
  --project=ageless-lamp-251200
```

**オプションB（--update-env-vars 利用時、最速）**:

```bash
gcloud functions deploy generate-design-suggestion \
  --gen2 --region=asia-northeast1 \
  --update-env-vars=USE_RAG=false \
  --project=ageless-lamp-251200
```

**オプションC（トラフィック瞬時戻し / 非常用）**: 直前 revision にトラフィック100%戻す

```bash
# 直前の安定 revision 名を控えてある前提
gcloud run services update-traffic generate-design-suggestion \
  --to-revisions=generate-design-suggestion-00031-weh=100 \
  --region=asia-northeast1 --project=ageless-lamp-251200
# 環境変数を戻すのと実質等価。ただし Cloud Run Gen2 層の操作
```

### Step 3. 反映確認

```bash
gcloud functions describe generate-design-suggestion \
  --region=asia-northeast1 --project=ageless-lamp-251200 \
  --format="value(serviceConfig.environmentVariables.USE_RAG,serviceConfig.revision,state)"
# 期待: false (または空)  新revision  ACTIVE
```

### Step 4. 切り戻し後スモークテスト

```bash
curl -s -X POST "https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/design-suggestion-agent" \
  -H "Content-Type: application/json" \
  -d '{"initiativeId":"a3EIe000000AulqMAC"}' \
  --max-time 180 | python3 -c "
import sys,json
d=json.load(sys.stdin)
tools=[t.get('tool') for t in d.get('toolHistory',[])]
print('status=',d.get('status'))
print('processedBy=',d.get('processedBy'))
print('has get_product_spec?', 'get_product_spec' in tools)
"
# 期待:
#   status=completed
#   processedBy=Vertex AI gemini-2.5-flash (Agent)   ← ★baseline復帰の証拠（Agent = 既存、(RAG Agent) が消えていること）
#   has get_product_spec? True
```

### Step 5. Dashboard 確認

Dashboard で最新実行が `BASE` バッジになっていることを確認。

### Step 6. 作業完了ログ

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [rollback-done] RAG → baseline success" \
  >> ~/claude/bps-salesforce-demo/docs/in-progress/gcp-rag-cutover-runbook.log
```

---

## 5. トラブルシューティング

| 症状 | 原因候補 | 対処 |
|---|---|---|
| `status=incomplete` が返る | BQ 権限不足 / retrieve が空 | 前提チェック 2.1 [2] を再実行 / BQ `chunks` テーブルの行数を確認 |
| `403 Access Denied: bigquery.jobs.create` | SA に `bigquery.jobUser` なし | `gcloud projects add-iam-policy-binding ... --role=roles/bigquery.jobUser` |
| `retrieve_spec_chunks` が `0 hits` | クエリフィルタ不一致 / embedding次元不一致 | product_filter 値 (`a1000`/`e2000`) を確認。`documents` テーブルの `document_id` と照合 |
| Gemini 応答が 429 / RESOURCE_EXHAUSTED | Vertex AI レート制限 | `gcloud alpha monitoring metrics list` で `aiplatform.googleapis.com/prediction_api_error_count` 確認。数分待って再実行 |
| Cloud Functions がコールドスタートし過ぎる | min-instances 設定が0になっている | `gcloud functions describe` で `minInstanceCount` 確認。1に戻す |
| `processedBy` が期待と違う | 分岐コードが反映されていない | `gcloud functions describe` で revision が新しいか、USE_RAG が反映されているか確認 |
| デモ直前で不安 | — | 即座に Step 4. オプションC でトラフィック戻す |

---

## 6. デモ当日の運用メモ

### 6.1 タイムライン（推奨）

| タイミング | 作業 |
|---|---|
| デモ30分前 | Step 6.2「ウォームアップ」を1回実行 |
| デモ15分前 | Step 6.3「min-instances=2 に増量」を実行 |
| デモ5分前 | Step 6.2「ウォームアップ」を**もう1回**実行（2台目のインスタンスも温める） |
| デモ本番 | LWC / IoT trigger を通常操作 |
| デモ終了直後 | Step 6.4「min-instances=1 に戻す」（コスト節約）|

**注**: Claude Code に「今日Geminiのデモやります」等と伝えれば、Step 6.2+6.3 が自動実行される（memory `feedback_demo_day_warmup.md` に記録済み）。

### 6.2 ウォームアップ手順

両シナリオのエンドポイントを1回ずつ叩き、Cloud Functions インスタンス / BQ Client / Vertex AI Client / SF JWT トークンをウォーム状態にする。

```bash
# 両シナリオを並列実行（レスポンスは捨てる）
curl -s -X POST "https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/design-suggestion-agent" \
  -H "Content-Type: application/json" \
  -d '{"initiativeId":"a3EIe000000AulqMAC"}' --max-time 120 > /dev/null &

curl -s -X POST "https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/equipment-alert" \
  -H "Content-Type: application/json" \
  -d '{"assetId":"02iIe00000165UeIAI","sensorType":"セル温度","value":47.5,"threshold":45.0,"location":"Bangkok"}' --max-time 120 > /dev/null &

wait
```

**効果**: 初回リクエスト25〜30秒が2回目以降相当（同じ25〜30秒）に安定。初回の BQ client 初期化で本番1発目に +5秒乗るのを防ぐ。

### 6.3 min-instances=2 に増量

```bash
gcloud run services update generate-design-suggestion \
  --min-instances=2 --region=asia-northeast1 \
  --project=ageless-lamp-251200
```

連続デモで2件続けて押された場合に2つ目のリクエストもウォーム状態で処理できるようにする。追加コストは月換算 ¥800（1日だけなら ¥30前後）。

### 6.4 min-instances=1 に戻す（デモ後）

```bash
gcloud run services update generate-design-suggestion \
  --min-instances=1 --region=asia-northeast1 \
  --project=ageless-lamp-251200
```

戻し忘れ監視ポイント：Budget アラート（50%=¥1,500）が鳴ったら要確認。

### 6.5 デモ中の安全策

- Dashboard を別タブで開いておく（状況把握用）
- 切り戻しコマンドをターミナルに貼り付けた状態でスタンバイ（§4 参照）
- 1回の失敗でパニック切り戻しをしない。iteration / status を確認してから判断
- 429 が出た場合は**数分待って**から再試行（バックオフ実装がないため）

### 6.6 本番デモ後のフォローアップ

- Dashboard で当日の baseline/rag 混在状況を記録（スクショでも可）
- GCS `runs-rag/` の実行ログをいくつかダウンロードして設計文書のエビデンスに追加
- Budget 当月消費を確認
- min-instances=1 に戻し忘れていないか確認

### 6.7 Gemini 側のレスポンス改善策（将来検討）

ウォームアップとmin-instances は Cloud Functions 側のみ効果。Vertex AI Gemini のレスポンス変動は別軸で、根本対策は以下のみ：

| 対策 | コスト | 推奨度 |
|---|---|---|
| **Provisioned Throughput** (Vertex AI 予約容量) | 月 $数千〜 | ❌ 個人デモには過剰 |
| **Quota 増加リクエスト** (コンソールから申請) | 無料（審査数日〜） | 🔺 本格運用時 |
| 何もしない（現状） | 無料 | ⭕ 今のデモ規模ならこれで十分 |

---

## 7. 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-04-22 | 初版作成。`USE_RAG` 環境変数方式を前提に切替・切り戻し手順を手順化 |
