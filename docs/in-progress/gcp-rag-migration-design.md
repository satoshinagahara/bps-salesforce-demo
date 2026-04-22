# GCP Product Engineering Agent — RAG 実装への移行設計

> **目的**: 現行の「製品名キーワード → GCS固定パス」マッピングによる仕様書・図面取得処理を、Vertex AI Embeddings + BigQuery Vector Search を用いた RAG 実装に置き換える。
> **ステータス**: 設計 / Phase 1 着手前
> **関連**: [gcp-demo-build-log.md](./gcp-demo-build-log.md) / [gcp_demo_design_concept.md](../concepts/gcp_demo_design_concept.md)

---

## 1. 背景と動機

### 1.1 現行実装の位置づけ

シナリオ1（製品改善提案）・シナリオ2（IoT異常アラート）の両方で、Product Engineering Agent は GCS 上の PDF 仕様書・PNG 図面を取得して Gemini に添付している。ファイル特定は [product_engineering_agent.py:45-56](../../gcp/generate-design-suggestion/product_engineering_agent.py#L45-L56) の `PRODUCT_ASSETS` 辞書による**製品名キーワード部分一致**で行われており、A-1000 / E-2000 の2製品ペア（仕様書1 + 図面1）× 2 = 4ファイルに固定。

これはデモとしては十分機能しているが、「本番っぽいアーキテクチャ」としての体裁には RAG 化が必要。ビルドログ §6 にも本番移行時の課題として明記済み。

### 1.2 本移行の目的

- **本番デモ時の説明責任**: 「これは RAG である」と明示できるアーキテクチャに置き換える
- **現行デモを壊さない**: LWC / Apex / カスタムオブジェクト / FlexiPage は一切変更しない
- **コスト制約厳守**: 月 ¥3,000 以内（ポケットマネー。予算超過したら即座に切り戻し）

### 1.3 非目標

- 本番運用に耐える RAG 構築（Vector Search エンドポイント常駐・VPC-SC・監査ログ等は対象外）
- 取り込みパイプラインの自動化（Cloud Scheduler / Composer 連携は対象外）
- 新規ファイル形式対応や画像検索（図面ベクトル検索）

---

## 2. アーキテクチャ設計

### 2.1 全体像

```
[インジェスト: 手動 1回実行]
仕様書PDF × 2  ─────┐
                    ├─> pdfminer でセクション分割 ─────┐
図面PNG × 2   ─────┤                                   ├─> Vertex AI Embeddings
                    └─> Gemini 2.5 Flash でキャプション化 ┘   (text-multilingual-embedding-002)
                                                                    │
                                                                    ▼
                                               BigQuery: bps_rag.chunks
                                               (embedding + メタデータ)
                                               + CREATE VECTOR INDEX

[リトリーブ: エージェント実行時]
Agent Tool: retrieve_spec_chunks(query, product_filter)
   │
   ├─> クエリを Vertex AI Embeddings で埋め込み化
   ├─> BigQuery VECTOR_SEARCH で kNN クエリ + メタデータフィルタ
   ├─> ヒットchunkの related_* メタデータから関連資産を引き寄せ
   └─> Gemini に context として返却
```

### 2.2 データモデル（BigQuery）

**データセット**: `bps_rag`（`asia-northeast1`）

#### テーブル `documents` (軽量マスタ)

| カラム | 型 | 用途 |
|---|---|---|
| `document_id` | STRING | 例: `a1000`, `e2000` |
| `product_keywords` | ARRAY<STRING> | マッチング用 |
| `product_display_name` | STRING | 例: "A-1000 大型風力タービン" |
| `spec_gcs_path` | STRING | 原本PDFパス |
| `diagram_gcs_paths` | ARRAY<STRING> | 原本図面パス |

#### テーブル `chunks` (本体)

| カラム | 型 | 用途 |
|---|---|---|
| `chunk_id` | STRING | 例: `a1000::spec::sec3.2` |
| `document_id` | STRING | `documents` への参照 |
| `doc_type` | STRING | `spec` / `figure` |
| `section` | STRING | 例: `3.2`（specのみ） |
| `page` | INT64 | 例: 3（specのみ） |
| `figure_id` | STRING | 例: `fig2`（figureのみ） |
| `figure_title` | STRING | 例: `ブレードピッチ制御機構 配置図`（figureのみ） |
| `related_figure_ids` | ARRAY<STRING> | specから参照する図面（本文中の「Fig.2参照」から抽出） |
| `related_section` | STRING | figureが対応するsection |
| `text` | STRING | チャンク本文（specは原文、figureはGemini生成キャプション） |
| `char_count` | INT64 | トリム判断用 |
| `embedding` | ARRAY<FLOAT64> | 次元数は使用モデルに依存（768 or 1536） |
| `embedding_model` | STRING | 例: `text-multilingual-embedding-002` |
| `ingested_at` | TIMESTAMP | 再インジェスト判定用 |

**ベクトルインデックス**:
```sql
CREATE VECTOR INDEX chunks_embedding_idx
ON bps_rag.chunks(embedding)
OPTIONS(index_type='IVF', distance_type='COSINE');
```

### 2.3 図面の扱い（設計上の重要判断）

先行議論で決定済みの方針を明示する：

- **図面そのものはベクトル化しない**（テキスト問い合わせとの意味的マッチングが成立しないため）
- **図面 → Gemini Vision で構造化テキスト記述を生成 → spec と同じテキスト埋め込み空間に格納**
- **仕様書と図面のリレーションはメタデータ（`related_figure_ids` / `related_section`）で保持**
- リトリーブは**2段階**:
  1. kNN検索で上位 N 件を取得
  2. 各ヒットの `related_*` メタデータを辿って関連資産を展開し、Geminiへ context として同梱

これにより、ヒット精度（テキスト検索の強み）と引用網羅性（仕様書・図面のセット参照）を両立する。

### 2.4 Agent ツール設計の差分

現行の10ツールのうち、**以下3つを置換**。それ以外は無変更で流用。

| 現行ツール | RAG版ツール | 差分 |
|---|---|---|
| `get_product_spec(product_name)` | **削除** | 個別仕様書の一括取得は RAG では不要 |
| `get_product_diagram(product_name)` | **削除** | 同上 |
| `generate_signed_urls(product_name)` | `get_original_asset_url(document_id, asset_type)` | LWC プレビュー用途の Signed URL 生成は必要。引数をdocument_idに変更 |
| — | 🆕 `retrieve_spec_chunks(query, product_filter, top_k=5)` | RAG の中心となるツール |

`retrieve_spec_chunks` の戻り値:
```jsonc
{
  "chunks": [
    {
      "chunk_id": "a1000::spec::sec3.2",
      "doc_type": "spec",
      "document_id": "a1000",
      "section": "3.2",
      "page": 3,
      "text": "...",
      "score": 0.87,
      "related_figure_ids": ["a1000::fig2"]
    },
    ...
  ],
  "expanded_figures": [
    {
      "chunk_id": "a1000::fig2",
      "figure_title": "ブレードピッチ制御機構 配置図",
      "text": "<キャプション>",
      "related_section": "3.2"
    }
  ]
}
```

### 2.5 system_instruction の変更

現行の `SYSTEM_INSTRUCTION_DESIGN_SUGGESTION` / `SYSTEM_INSTRUCTION_EQUIPMENT_ALERT` を RAG 向けに書き換える：

- 「仕様書PDFと図面を読み解き」→「retrieve_spec_chunks で関連チャンクを取得し、ヒットセクション番号を根拠にして診断」
- 「仕様書のセクション番号を必ず引用する」は維持
- リトリーブクエリの組み立て方（施策Why / ニーズvoice / センサー種別 + 閾値超過量）をガイド

---

## 3. 並走戦略

### 3.1 基本方針

- **現行コードは一切変更しない**
  - `product_engineering_agent.py`, `main.py` の既存エンドポイントハンドラはそのまま
- **RAG版は別モジュール + 別エンドポイント**で並走
  - `product_engineering_agent_rag.py` を新規追加
  - `main.py` に `/design-suggestion-agent-rag` / `/equipment-alert-rag` の2ルートを追加するのみ
- **検証完了後の切り替えは3段階のロールバック経路を維持**

### 3.2 ファイル構成（追加分のみ）

```
gcp/generate-design-suggestion/
  product_engineering_agent_rag.py        # 🆕 RAG版エージェント本体
  rag/
    __init__.py
    retriever.py                          # 🆕 BigQuery VECTOR_SEARCH ラッパ
    embeddings.py                         # 🆕 Vertex AI Embeddings API ラッパ
  scripts/
    rag_ingest.py                         # 🆕 1回実行用インジェストスクリプト
    rag_caption_diagrams.py               # 🆕 図面キャプション生成スクリプト
    rag_build_index.py                    # 🆕 BQ スキーマ作成 + VECTOR INDEX 構築
```

### 3.3 切り替え戦略

検証完了後、以下3通りのいずれかで切り替え。安全度の高い順：

| 方法 | 切り戻し速度 | ロールバック経路 |
|---|---|---|
| 環境変数 `USE_RAG=true` で `_handle_design_suggestion_agent` 内分岐 | env更新+再起動のみ | env を戻すだけ |
| ハンドラ中身をRAG呼出に差替、旧`run_agent`は残置 | 要デプロイ | コード上に旧呼出経路が残存 |
| 旧 `product_engineering_agent.py` を削除 | NG | — |

**当面は方法1**（環境変数フラグ）を採用。最低 2〜3ヶ月は旧コード残置。

---

## 4. 段階的実装計画

### Phase 0: 事前準備 ✅（本ドキュメントで完了）

- [x] 設計確定
- [ ] GCP Budget アラート設定（¥3,000上限、50% / 90% / 100%）← 次タスク
- [ ] BigQuery API 有効化確認

### Phase 1: インジェスト（1回きり実行）

**目標**: BQ `bps_rag.chunks` テーブルにA-1000 / E-2000 の仕様書・図面を全件取り込み、ベクトルインデックス張り終える。

**ファイル配置**:
```
gcp/
  rag-scripts/                 # 🆕 インジェスト系（Cloud Functionsにはデプロイしない）
    requirements.txt
    build_index.py             # BQ データセット・テーブル・VECTOR INDEX 作成
    caption_diagrams.py        # 図面 Gemini Vision でキャプション化 → GCS保存
    ingest.py                  # Markdown分割 → 埋め込み生成 → BQ投入
    test_retrieve.py           # 動作確認（いくつかのクエリで上位ヒットを見る）
```

**実装要点**:

1. **パース元は `gcp/assets/specs/*.md`**（PDFではなく原本 Markdown）
   - 構造が `# P.x` → `## x.x` → `### x.x.x` と階層化されており正規表現で安定分割可能
   - `pdfminer` 依存を削減

2. **チャンク粒度は `##` セクション単位**
   - 例: A-1000 の §3.2 「風速域別の制御モード」を1チャンク、§3.3 を1チャンク…
   - 仕様書が短いため、`###` サブセクションまで刻むと細かすぎる

3. **図面とセクションの関連は手動マッピング**
   - MD本文中には「→ P.3参照」のような緩い参照しかなく、正規表現では精度不足
   - `documents` マスタに `figure → 関連セクション範囲` を hardcode
     - A-1000 `blade_pitch_control_diagram`: §3.1〜3.5 全体
     - E-2000 `e2000_bms_architecture`: §3.1〜3.5 全体
   - リトリーブ時、ヒットしたspecチャンクのsection番号が関連範囲に入れば図面を展開

4. **キャプション生成は1回きり**
   - Gemini 2.5 Flash に図面PNG + 製品コンテキストを渡し、構造化テキストを生成
   - 結果は `gcp/assets/diagrams/<name>.caption.md` としてローカル保存 + GCS `diagrams/<name>.caption.md` にも同置
   - 品質確認のため目視チェック前提。必要なら手直ししてコミット

5. **埋め込みモデル**: `text-multilingual-embedding-002`（768次元、日本語対応、コスト最小）

6. **BQ配置**: `asia-northeast1`（既存GCS/Cloud Functionsと同一リージョン）

**成功基準**:
- `chunks` テーブルに20〜40行程度が投入される（2 docs × 10前後のセクション）
- 「低風速域での制御最適化」等のクエリで A-1000 §3.2 / §3.4 が上位ヒットする
- 「高温環境でのバッテリー寿命」クエリで E-2000 §3.2 / §3.4 が上位ヒットする

**推定コスト**: ¥60程度（1回きり）

**成功基準**:
- `chunks` テーブルに数十〜百行程度が投入される
- 「低風速域での制御最適化」等のクエリで A-1000 §3.2 が上位ヒットする
- 「高温環境でのバッテリー寿命」クエリで E-2000 関連セクションが上位ヒットする

**推定コスト**: ¥60程度（1回きり）

### Phase 2: RAG エージェント実装

1. `rag/embeddings.py`: Vertex AI Embeddings API ラッパ（クエリ埋め込み化）
2. `rag/retriever.py`: BQ `VECTOR_SEARCH` クエリ + メタデータ展開
3. `product_engineering_agent_rag.py`:
   - `retrieve_spec_chunks` / `get_original_asset_url` ツール実装
   - 残り7ツール（`get_initiative_info` 等）は既存モジュールから流用
   - `run_agent_rag(mode=...)` 実装
   - system_instruction 書き換え
4. `main.py` に `/design-suggestion-agent-rag` / `/equipment-alert-rag` 追加
5. デプロイ（`requirements.txt` に `google-cloud-bigquery`, `pdfminer.six` 追記）

### Phase 3: 検証ハーネス

1. 既存 Initiative 2件・Asset 2件で新旧両エンドポイントを叩き、GCS `runs/` の実行ログを比較
2. 比較観点:
   - 引用セクション番号の一致・妥当性
   - iteration数・トークン使用量・レイテンシ
   - 生成テキストの具体性（現行と同等以上か）
   - false positive（無関係セクションの混入）の有無
3. 必要なら LWC に「RAG版で試す」デバッグボタンを追加

### Phase 4: 切り替え

1. 環境変数 `USE_RAG=true` を Cloud Functions に設定
2. `_handle_design_suggestion_agent` / `_handle_equipment_alert` に分岐を入れる（1〜2行）
3. LWC から通常デモ経路で動作確認
4. 問題なければフラグ据え置き、旧コードは当面残置

### Phase 5 (将来): クリーンアップ

- 切替後3ヶ月以上安定稼働したら旧コード削除検討
- この時点で `docs/design/gcp-rag-implementation.md` に正式ドキュメント化し、本書を `docs/archive/` に移動

---

## 5. コスト試算

| 項目 | 発生タイプ | 見積 |
|---|---|---|
| Phase 1 インジェスト（埋め込み生成 + キャプション生成） | 1回限り | ¥60 |
| BigQuery ストレージ（chunks テーブル数MB） | 常時 | ¥0（10GB無料枠内） |
| BigQuery Vector Search クエリ | 月10回程度 | ¥数十 |
| Vertex AI Embeddings クエリ時 | 月10回程度 | ¥数円 |
| Gemini 2.5 Flash 呼出 | 現行継続 | 月 ¥数百 |
| Cloud Functions min-instances=1 | 現行継続 | 月 ¥800 |
| **RAG追加分合計** | | **月 ¥500〜1,000** |
| **デモ環境総額** | | **月 ¥1,500〜2,000** |

**上限 ¥3,000 に対して 約 1/2 以下で収まる見込み**。

### コスト超過時の対応策

- BQ Vector Search の代わりに Python 側でブルートフォース kNN（数十チャンクなら十分速い）
- `min-instances=0` に変更（コールドスタートは許容、月 ¥800節約）
- 検証中に過剰な回数叩かない（同じペイロードを繰り返さない）

---

## 6. リスクと対応

| リスク | 対応 |
|---|---|
| BigQuery Vector Search API の価格変更 / 仕様変更 | Budget アラートで即検知。必要なら pgvector on Cloud SQL に退避 |
| PDF セクション分割の精度不足 | 仕様書が4ファイル固定なので、必要なら手動補正OK |
| 図面キャプションの品質不足 | Gemini Vision の結果を目視確認し、必要なら手直ししてGCSに保存 |
| リトリーブ結果が現行添付マルチモーダルより劣化 | 並走期間中に新旧比較で検出、切替判断保留 |
| LWC側の `referenceSpec` / `referenceDiagram` フィールド値フォーマット不一致 | RAG版でも同形式（例: `P.4 §3.2 起動モード表` / `Fig.2 ブレードピッチ制御機構 配置図`）で出力するよう system_instruction 側で制御 |

---

## 7. 未決事項（着手中に決める）

- [ ] 埋め込みモデル選定: `text-multilingual-embedding-002` (768次元) v.s. `gemini-embedding-001` (3072次元)。後者はコスト高・精度高。デモ規模なら前者で十分と想定
- [ ] チャンク粒度: セクション単位 v.s. 段落単位。仕様書が短いので**セクション単位（§3.2 全体で1チャンク）が妥当**と仮判断
- [ ] `top_k` の既定値: 3 / 5 / 10 のどれ。並走検証時に最適化
- [ ] `rag/` ディレクトリを Cloud Functions のデプロイ対象に含めるビルド設定（`functions-framework` は同階層以下を自動包含するので追加設定不要の見込み）

---

## 8. 実装結果（Phase 1〜3 完了）

### Phase 1 実績
- BQ dataset `bps_rag` (asia-northeast1) + `documents` / `chunks` テーブル作成
- 図面2枚 Gemini Vision でキャプション化 → ローカル + GCS 保存
- チャンク22行投入（spec 20 + figure 2）× 768次元 `text-multilingual-embedding-002`
- VECTOR INDEX は行数不足（< 5000）で skip、brute-force VECTOR_SEARCH で代替
- 実データ（Initiative + 紐付くNeedsCard）でのクエリで両製品とも期待セクション上位ヒット

### Phase 2 実績
- `gcp/generate-design-suggestion/rag/retriever.py` 実装（query埋め込み + BQ VECTOR_SEARCH + related_figure_ids展開）
- `gcp/generate-design-suggestion/product_engineering_agent_rag.py` 実装
  - 既存ツール7つ（SF読取・書戻・severity/opportunity計算）をそのまま流用
  - 削除: `get_product_spec` / `get_product_diagram` / `generate_signed_urls`
  - 追加: `retrieve_spec_chunks` / `get_original_asset_url`
  - マルチモーダル添付（PDF/PNGバイト）廃止。テキストチャンクのみ
- `main.py` にパスルーティング2本追加: `/design-suggestion-agent-rag` / `/equipment-alert-rag`
- `requirements.txt` に `google-cloud-bigquery>=3.27.0` 追加
- Cloud Functions 再デプロイ（revision 00031）
- IAM: サービスアカウント `bps-demo-sa` に `roles/bigquery.jobUser` + `roles/bigquery.dataViewer` を追加

### Phase 3 実績: 新旧両エンドポイントで動作比較

| 項目 | 既存 `/design-suggestion-agent` | RAG `/design-suggestion-agent-rag` |
|---|---|---|
| **A-1000 施策** (ニーズ0件) | ✅ iter=7, §3.2/§3.4 引用 | ✅ iter=5, §3.2/§3.4/§1.3 引用 |
| **E-2000 施策** (ニーズ3件) | 未計測 | ✅ iter=6, §1.3/§3.2/§3.4 引用 + 液冷検討まで言及 |
| **E-2000 設備異常** (47.5℃/閾値45℃) | 未計測 | ✅ iter=6, §3.4 既知課題 top hit, severity=中, 想定商談¥108M |
| 参照資料タイトル | Fig.2 ブレードピッチ制御機構 配置図 | Fig.1 ブレードピッチ制御機構 配置図 / Fig.1 BMS 3階層アーキテクチャ図 |
| Signed URL | ✅ spec/diagram 両方 | ✅ spec/diagram 両方（get_original_asset_url経由） |
| SF 書き戻し | ✅ | ✅ A-1000: `a47Ie000000g9LOIAY` / E-2000: `a47Ie000000g9LTIAY` / Alert: `a48Ie000001DTicIAG` |

### 新旧の差分

1. **iteration数削減**: A-1000 で 7→5。`get_product_spec + get_product_diagram` の2呼出が `retrieve_spec_chunks` 1本に集約
2. **引用セクションの網羅性向上**: 既存版は §3.2/§3.4 の2箇所中心だったが、RAG版は §1.3 市場セグメントも自然に引用し、ビジネス文脈（東南アジア需要など）が suggestionText に乗る
3. **マルチモーダル廃止によるtoken削減**: PDF/PNGバイトをPart化して送っていた分が消え、テキストチャンクのみに。レイテンシも一定化
4. **runs ログ分離**: 新旧の実行ログは GCS 上の `runs/` / `runs-rag/` に分離保存

### 切り替え可否の判断材料

- **精度**: 既存版と同等以上。既知設計課題を必ず引き、ビジネス文脈（市場セグメント）もカバー
- **レスポンス時間**: retrieve 1〜7秒（初回コールドは長め。2回目以降は ~1秒台）
- **可用性**: BigQuery Vector Search は brute-force モードで 22行を全走査してもミリ秒オーダー
- **コスト**: 追加実費は月 ¥数十（embedding + BQクエリ）

### 残タスク（Phase 4以降）

- [ ] Phase 4a: `main.py` に `USE_RAG` 環境変数分岐コードを追加・デプロイ（切替準備）
- [ ] Phase 4b: 切替・切り戻し実行 → 詳細は [gcp-rag-cutover-runbook.md](./gcp-rag-cutover-runbook.md) 参照
- [ ] Phase 5: 3ヶ月安定稼働後に旧コード削除、本書を `docs/design/gcp-rag-implementation.md` として正式化

---

## 9. 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-04-22 | 初版作成。設計確定 |
| 2026-04-22 | Phase 1 完了: BQ構築、キャプション生成、22チャンク投入、実データ検証 |
| 2026-04-22 | Phase 2 完了: `rag/retriever.py` + `product_engineering_agent_rag.py` 実装、Cloud Functions 並走デプロイ（revision 00031）、`bps-demo-sa` に BigQuery IAM 付与 |
| 2026-04-22 | Phase 3 完了: 新旧両エンドポイントで A-1000 / E-2000 / equipment-alert の3パターン全成功。iteration数削減、引用セクション網羅性向上を確認 |
| 2026-04-22 | Phase 4 完了: `USE_RAG` 環境変数分岐を main.py に実装、`USE_RAG=true` で切替デプロイ（revision 00033-dad）。スモーク両シナリオ成功（processedBy="RAG Agent"）|
| 2026-04-22 | UI整合性対応: LWC designSuggestionGcp STEPS / IoT /trigger 5ステップ / pipeline フッターを RAG 実装に合わせて更新。Dashboard `runs/` vs `runs-rag/` のprefix単位ソートバグ修正 |
| 2026-04-23 | 運用整備: ランブック §6 にデモ当日のウォームアップ/min-instances増量手順を追記。memory `feedback_demo_day_warmup.md` でデモ日自動発火を記録 |
