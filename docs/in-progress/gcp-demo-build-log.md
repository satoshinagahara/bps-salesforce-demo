# GCP 連携構築ログ — Salesforce × Product Engineering Agent

> **目的**: Salesforce と GCP Vertex AI を統合し、製品施策に対する設計改善提案（シナリオ1）と IoT 設備異常の業務的解釈（シナリオ2）を同じ Product Engineering Agent で処理するデータパイプラインを構築する。
> **設計書**: [gcp_demo_design_concept.md](../concepts/gcp_demo_design_concept.md)

---

## 0. 確定済み UI/UX 決定事項

### シナリオ1（製品改善提案）

| 論点 | 決定 | 理由 |
|---|---|---|
| 配置先 | Product_Initiative__c（製品施策）レコードページ FlexiPage12 | ビジネス意思決定と技術提案の交差点 |
| エントリーポイント | タブ「製品改善提案 by GCP」 | SFとGCPの境界が明示的 |
| 処理中表示 | 4ステップ進捗表示（CSSスピナー、オーバーレイなし） | 実際のツール呼出順に対応 |
| 結果表示 | タブ内インライン + スライドイン + 参照資料プレビュー | Geminiが参照したPDF/図面が画面上で見える |
| 入力プレビュー | ボタン前に施策情報 + 紐付くニーズカード一覧 | 「何がGCPに渡るか」を画面で明示 |
| Agent tool_history | 結果カード下部に実行ログを表示 | ブラックボックス化を回避、CEらしい透明性 |
| 履歴 | 毎回新規生成のみ | 収録用シンプル優先 |

### シナリオ2（IoT設備異常アラート）

| 論点 | 決定 | 理由 |
|---|---|---|
| 配置先 | Asset（納入商品）レコードページ FlexiPage `Asset_BPS_Demo` | IoTの主語「この設備」が明確 |
| トリガー | HTMLボタン（Cloud Functions 同梱）でイベント発火 | GCP側の操作だと明示 |
| 検知値入力 | HTML上で編集可能 | リアリティ向上 |
| 処理中表示 | 5ステップ進捗演出 + 完了後の Agent ツール呼出履歴 | 体感遅延の緩和 + 実行ログで透明性 |
| アラート結果UI | Asset ページ「設備アラート by GCP」タブ | 設備起点で見るのが自然 |

### データパイプライン設計変更の経緯（ニーズカード→製品施策へ移動）

当初シナリオ1はニーズカード（Needs_Card__c）レコードページにGCP連携タブを配置する構想だったが、以下の理由で製品施策（Product_Initiative__c）に移動した：

1. **ビジネスと技術の交差**: 製品施策はビジネス意思決定（Why/What/Who）が集約されるレコード。GCPの技術提案を返すことで「ビジネスの意思と技術の具体策が合流する」
2. **入力情報の豊かさ**: 製品施策には Why/What/ターゲット顧客像 + Initiative_Need__c 経由で**複数のニーズカード**が紐付く → Geminiへの入力が格段に豊かになる
3. **パイプラインの一貫性**: 「面談メモ → ニーズ構造化 → ターゲッティング → 製品施策（ビジネス意思決定）→ GCPが技術的裏付けを返す」という一本道のデータパイプラインが成立

---

## 1. アーキテクチャ全体像

### 1.1 Salesforce 側データパイプライン

```
[シナリオ1: 人発の問い合わせ]
面談記録 → ニーズカード → ターゲッティングLWC → 製品施策（Product_Initiative__c）
                                                      └─ [タブ] 製品改善提案 by GCP
                                                           ↕
                                                       Product Engineering Agent

[シナリオ2: 設備発のイベント]
IoTイベント(HTMLトリガー) → Product Engineering Agent → Asset レコード
                                                             └─ [タブ] 設備アラート by GCP
```

### 1.2 GCP 側の統一エージェント構成

```
┌────────────────────────────────────────────────────────────────────┐
│ GCP Project: ageless-lamp-251200 (表示名: bps-demo-project)         │
│                                                                     │
│  Cloud Functions Gen2 (Python 3.12, asia-northeast1)               │
│  generate-design-suggestion                                        │
│    ├─ POST /design-suggestion-agent ← シナリオ1エントリ              │
│    ├─ POST /equipment-alert         ← シナリオ2エントリ              │
│    ├─ POST /prompt                  ← needsAnalysisV2（非Agent）     │
│    ├─ POST /                        ← シナリオ1固定パイプライン(旧)  │
│    ├─ GET  /trigger                 ← IoTトリガーHTMLページ          │
│    └─ GET  /signed-url              ← GCSオブジェクトのSigned URL生成│
│                                                                     │
│  product_engineering_agent.py（エージェントコア）                   │
│    ├─ Vertex AI Gemini 2.5 Flash (us-central1)                     │
│    ├─ system_instruction をモード別切替 (design_suggestion/equipment_alert) │
│    ├─ 10ツールを FunctionDeclaration として登録                     │
│    ├─ ツール呼出ループ (max 15 iterations)                         │
│    └─ tool_history をレスポンスに含める                            │
│                                                                     │
│  Cloud Storage: gs://bps-design-assets (asia-northeast1)           │
│    ├─ specs/bps_spec_wind_turbine_a1000.pdf (5p, 478KB)            │
│    ├─ specs/bps_spec_battery_e2000.pdf (5p, 515KB)                 │
│    ├─ diagrams/blade_pitch_control_diagram.png (79KB)              │
│    ├─ diagrams/e2000_bms_architecture.png (109KB)                  │
│    ├─ products/a1000_wind_turbine.png (Imagen生成)                 │
│    └─ products/enercharge_pro_e2000.png (Imagen生成)               │
│                                                                     │
│  Vertex AI Imagen 3.0 (us-central1) — 製品写真生成用                │
└────────────────────────────────────────────────────────────────────┘
```

### 1.3 実装方針

- **統一 Product Engineering Agent**: シナリオ1/2 が同じエージェント・同じツール基盤を共有（system_instruction だけモード別）
- **SF認証**: JWT Bearer Flow。sf CLI 既存の `server.key` を base64 化して Cloud Functions 環境変数に格納
- **min-instances=1** でコールドスタート回避、timeout=300秒でGemini応答遅延に耐える
- **tool_history** をレスポンスに同梱し、LWC / HTMLで実行ログを可視化

---

## 2. Salesforce 側の実装 ✅ 完了

### 2.1 カスタムオブジェクト

#### DesignSuggestion__c（製品改善提案）

配置先: Product_Initiative__c レコードページ

| API名 | 型 | 用途 |
|---|---|---|
| `Name` | AutoNumber `DS-{0000}` | — |
| `Initiative__c` | Lookup(Product_Initiative__c) | 主要な親レコード |
| `NeedsCard__c` | Lookup(Needs_Card__c) | 下位互換（任意） |
| `TargetProduct__c` | Text(255) | Geminiが推論した対象製品 |
| `TargetComponent__c` | Text(255) | 対象コンポーネント |
| `SuggestionText__c` | LongTextArea(32768) | 提案本文 |
| `ReferenceSpec__c` | Text(255) | 参照仕様書セクション |
| `ReferenceDiagram__c` | Text(255) | 参照図面 |
| `Priority__c` | Picklist | 高/中/低 |
| `ProcessedBy__c` | Text(100) | 「Vertex AI gemini-2.5-flash (Agent)」 |
| `GeneratedAt__c` | DateTime | — |
| `GcpRequestId__c` | Text(64) | トレース用 |

#### Equipment_Alert__c（設備アラート）

配置先: Asset レコードページ

| API名 | 型 | 用途 |
|---|---|---|
| `Name` | AutoNumber `EA-{0000}` | — |
| `Asset__c` | Lookup(Asset) | 親レコード |
| `Sensor_Type__c` | Picklist | セル温度 / 振動 / 充電サイクル / その他 |
| `Detected_Value__c` | Number(10,2) | 検知値 |
| `Threshold__c` | Number(10,2) | 閾値 |
| `Severity__c` | Picklist | 高/中/低 |
| `Detected_At__c` | DateTime | — |
| `Anomaly_Description__c` | LongTextArea(32768) | AI診断テキスト（仕様書引用付き） |
| `Recommended_Action__c` | LongTextArea(32768) | 推奨アクション（箇条書き） |
| `Estimated_Opportunity__c` | Currency | 想定商談機会金額 |
| `Opportunity_Rationale__c` | Text(255) | 商談機会算出根拠（納入価格×係数） |
| `ProcessedBy__c` | Text(100) | 「Vertex AI gemini-2.5-flash (Agent)」 |
| `GcpRequestId__c` | Text(64) | — |
| `Status__c` | Picklist | 新規/対応中/解決済 |

### 2.2 Apex クラス

| クラス | 役割 |
|---|---|
| `DesignSuggestionGcpController` | シナリオ1用。`getPreviewData` / `generateDesignSuggestion`（旧固定版）/ `generateDesignSuggestionAgent`（新エージェント版） |
| `EquipmentAlertController` | Asset 情報 + 過去アラート一覧を取得（LWC wire 用） |
| `AssetShowcaseController` | 納入商品LWC用。Asset情報 + 地図座標（ハードコード） + 画像 Signed URL |
| `NeedsAnalysisV2Controller` | （シナリオ外）ニーズ分析ダッシュボードV2。Vertex AI 直接呼出 |

### 2.3 LWC

| LWC | 配置先 | 役割 |
|---|---|---|
| `designSuggestionGcp` | Product_Initiative__c ページ | シナリオ1のUI。施策プレビュー + 4ステップ進捗 + 結果カード + PDF/図面プレビュー + Agent tool_history |
| `equipmentAlertGcp` | Asset ページ | シナリオ2の結果表示。最新アラート + 過去アラート一覧 |
| `assetShowcaseGcp` | Asset ページ | 納入商品情報。Imagen生成画像 + lightning-map で設置ロケーション表示 |
| `needsAnalysisDashboardV2` | アプリページ | （参考）ニーズ分析ダッシュボード（Trust Layer バイパス版） |

### 2.4 FlexiPage

| FlexiPage | 対象オブジェクト | タブ構成 |
|---|---|---|
| `FlexiPage12` | Product_Initiative__c | 施策説明 / 施策トレーサビリティ / **製品改善提案 by GCP** |
| `Asset_BPS_Demo` | Asset | **納入商品**（既定） / 設備アラート by GCP / 詳細 / 関連 |

### 2.5 外部接続 / 認証

- **Remote Site Setting**: `GCP_Design_Suggestion` = `https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net`
- **CSP Trusted Site**: `GCS_Storage` = `https://storage.googleapis.com`（img-src / frame-src / connect-src）
- **Connected App**: `GCP_Design_Suggestion`（GCP→SF 認証用、JWT Bearer Flow用）
- **権限セット**: `BOM_Full_Access` に全カスタムオブジェクト・全カスタムApexクラス・全フィールドを追加済み

---

## 3. GCP 側の実装 ✅ 完了

### 3.1 プロジェクト構成

| 項目 | 値 |
|---|---|
| Project 表示名 | `bps-demo-project` |
| **Project ID（実ID）** | `ageless-lamp-251200` |
| Project Number | `174999106767` |
| Billing Account | `010067-E62B2B-D634F6` |
| リージョン | `asia-northeast1`（Cloud Functions/Storage）/ `us-central1`（Vertex AI） |
| 有効化API | Cloud Functions, Cloud Build, Cloud Run, Artifact Registry, Vertex AI (aiplatform), Eventarc, IAM Credentials, Cloud Logging, Cloud Storage |

### 3.2 サービスアカウント

- `bps-demo-sa@ageless-lamp-251200.iam.gserviceaccount.com`
- 付与済みロール: `roles/aiplatform.user`, `roles/storage.objectViewer`, `roles/logging.logWriter`, `roles/iam.serviceAccountTokenCreator`（自己署名用）

### 3.3 Cloud Storage

バケット `gs://bps-design-assets` (asia-northeast1, uniform bucket-level access)

| パス | 用途 |
|---|---|
| `specs/bps_spec_wind_turbine_a1000.pdf` | A-1000 仕様書（5ページ、weasyprintで生成） |
| `specs/bps_spec_battery_e2000.pdf` | E-2000 仕様書（5ページ） |
| `diagrams/blade_pitch_control_diagram.png` | A-1000 図面（Pillow生成、79KB） |
| `diagrams/e2000_bms_architecture.png` | E-2000 BMS図面（Pillow生成、109KB） |
| `products/a1000_wind_turbine.png` | A-1000 製品写真（Imagen 3.0 生成） |
| `products/enercharge_pro_e2000.png` | E-2000 製品写真（Imagen 3.0 生成） |

### 3.4 Cloud Functions: `generate-design-suggestion`

| 項目 | 値 |
|---|---|
| 公開URL | `https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion` |
| ランタイム | Python 3.12 / Cloud Functions Gen2 / functions-framework |
| メモリ | 1 GiB |
| タイムアウト | 300 秒 |
| min-instances | 1（コールドスタート回避） |
| Service Account | `bps-demo-sa` |

#### ディレクトリ構成

```
gcp/generate-design-suggestion/
  main.py                            # ルーティング + HTMLトリガーページ
  product_engineering_agent.py      # エージェントコア（ツール + run_agent）
  requirements.txt
  .env.yaml                          # 環境変数（非コミット）
  .env.yaml.example
  test_local.py / test_writeback.py  # ローカルテスト
  test_request.json
```

#### エンドポイント一覧

| メソッド | パス | 用途 |
|---|---|---|
| POST | `/` | シナリオ1 固定パイプライン（旧、互換維持） |
| POST | `/design-suggestion-agent` | **シナリオ1 エージェント版（現用）** |
| POST | `/equipment-alert` | **シナリオ2 エージェント（IoT異常）** |
| POST | `/prompt` | 汎用プロンプト（needsAnalysisV2用、Trust Layerバイパス） |
| GET | `/trigger` | シナリオ2のIoTトリガーHTMLページ |
| GET | `/signed-url?path=...` | GCS オブジェクトの Signed URL 生成（LWC画像表示用） |

### 3.5 Product Engineering Agent 詳細

詳細は [gcp_demo_design_concept.md §7.5](../concepts/gcp_demo_design_concept.md) を参照。要点のみ記載：

- **10ツール**: get_initiative_info / get_linked_needs / get_asset_info / get_product_spec / get_product_diagram / generate_signed_urls / calculate_severity / estimate_opportunity / write_design_suggestion / write_equipment_alert
- **system_instruction** を `design_suggestion` と `equipment_alert` の2モードで切替
- **マルチモーダル**: PDF / PNG バイトを取得時に Part 化し、次ターンに添付して Gemini に渡す
- **429 リトライ**: 指数的バックオフで最大3回
- **tool_history**: 各ツール呼出の引数・結果サマリ・実行時間をレスポンスに同梱

### 3.6 Salesforce Connected App (GCP → Salesforce 認証)

- Connected App名: `GCP Design Suggestion Integration`
- 認証方式: **JWT Bearer Flow**
- sf CLI 既存の `server.key` を base64 化して `SF_PRIVATE_KEY_B64` 環境変数に設定
- Consumer Key は Cloud Functions の `SF_CONSUMER_KEY` 環境変数に設定
- 当初 Client Credentials Flow を検討したが、デモorgで有効化オプションが表示されなかったため JWT Bearer に切替

---

## 4. サンプル資産とデモデータ ✅ 完了

### 4.1 製品仕様書PDF / 図面PNG

| 資産 | 生成方法 | 仕込み |
|---|---|---|
| `bps_spec_wind_turbine_a1000.pdf` | Markdown → Pandoc(HTML) → weasyprint(PDF) | P.3 §3.2「起動モード3.5-5.0m/sは発電効率最適化対象外」。§3.4で低風速域の翼角度制御パラメータ未最適化を既知課題として記載 |
| `bps_spec_battery_e2000.pdf` | 同上 | 高温環境（35-45℃）での充放電プロファイル最適化が未対応であることを仕様書・既知課題に記載 |
| `blade_pitch_control_diagram.png` | Pillow 自動生成 | ブレード+アクチュエータ配置の模式図 |
| `e2000_bms_architecture.png` | Pillow 自動生成 | BMS 3階層構成の模式図 |

### 4.2 製品写真（Imagen 3.0 生成）

| 資産 | プロンプト要点 |
|---|---|
| `products/a1000_wind_turbine.png` | 5MW級風力タービン3基、山岳地帯、BPSロゴ入り、写真風 |
| `products/enercharge_pro_e2000.png` | 20ftコンテナ型蓄電システム、工業施設背景、BPSロゴ入り、写真風 |

### 4.3 Salesforce デモデータ

| データ | 用途 |
|---|---|
| Product_Initiative__c `a3EIe000000AulqMAC` | 「A-1000 低風速域対応強化」 + 紐付くNeedsCard 3件 |
| Product_Initiative__c `a3EIe000000AullMAC` | 「蓄電システム高温環境対応強化」 + 紐付くNeedsCard 3件 |
| Asset `02iIe00000165VhIAI` | A-1000 大型風力タービン #003（中部第3拠点 / アライドパワー） |
| Asset `02iIe00000165UeIAI` | EnerCharge Pro #001（Bangkok Plant B / 東亜電子工業） |
| Task × 6件 | 各 Asset に紐付く活動履歴（シナリオに即した実績風） |

---

## 5. 実装ステップ（全進捗）

### シナリオ1（製品改善提案）

| # | ステップ | 状態 |
|---|---|---|
| 1 | GCP プロジェクト初期化 | ✅ |
| 2 | サンプル資産（PDF/図面）生成 + GCS アップロード | ✅ |
| 3 | Cloud Functions 初回デプロイ（固定パイプライン） | ✅ |
| 4 | DesignSuggestion__c + 権限セット | ✅ |
| 5 | Connected App + JWT 認証 | ✅ |
| 6 | Apex Controller + Remote Site Setting | ✅ |
| 7 | LWC `designSuggestionGcp` 初版 | ✅ |
| 8 | FlexiPage12 タブ追加 | ✅ |
| 9 | CSP Trusted Site（storage.googleapis.com） | ✅ |
| 10 | 参照資料プレビュー（PDF iframe / 図面img） | ✅ |
| 11 | **エージェント化**: 固定パイプライン → Function Calling | ✅ |
| 12 | LWC に Agent tool_history 表示追加 | ✅ |

### シナリオ2（IoT設備異常）

| # | ステップ | 状態 |
|---|---|---|
| 1 | Equipment_Alert__c カスタムオブジェクト | ✅ |
| 2 | Asset デモレコード作成（EnerCharge + A-1000） | ✅ |
| 3 | Product Engineering Agent 実装（Function Calling + 6ツール） | ✅ |
| 4 | HTML トリガーページ（Cloud Functions 同梱） | ✅ |
| 5 | LWC `equipmentAlertGcp` | ✅ |
| 6 | Asset FlexiPage `Asset_BPS_Demo` | ✅ |
| 7 | 検知値編集UI + 5ステップ進捗演出 + tool_history表示 | ✅ |
| 8 | estimate_opportunity を Asset Price ベースに改善 | ✅ |

### シナリオ共通拡張

| # | ステップ | 状態 |
|---|---|---|
| 1 | シナリオ1も Product Engineering Agent に統合（10ツール体制） | ✅ |
| 2 | Imagen 3.0 による製品写真生成（2枚） | ✅ |
| 3 | LWC `assetShowcaseGcp`（画像 + lightning-map） | ✅ |
| 4 | Asset Task 活動履歴のシード（6件） | ✅ |
| 5 | Cloud Functions timeout 180→300秒（Geminiレイテンシ耐性） | ✅ |

### 残作業

| タスク | 優先度 |
|---|---|
| 収録リハーサル | 高 |
| 動画収録（バックアップ用） | 中 |

---

## 6. デモ簡略化と本番構成の差異

詳細は [gcp_demo_design_concept.md §7.5〜§8](../concepts/gcp_demo_design_concept.md) に詳述。要約：

| デモでの簡略化 | 本番で必要な構成 |
|---|---|
| 仕様書/図面を製品名キーワードでGCSから固定取得 | RAG（Vertex AI Embeddings + Vector Search）で動的検索 |
| GCSに手動アップロード | PLM/CADシステムからの定期同期（Transfer Service / Cloud Composer） |
| 単一エージェント・10ツール | マルチエージェント（Sales/Field Service/Market Intelligence）+ オーケストレーター |
| Python ループによるFunction Calling | Agent Development Kit (ADK) + Agent Builder 併用 |
| tool_history を レスポンス同梱のみ | Cloud Trace + Vertex AI Logging + Evaluation + Monitoring |
| Gemini組込 Safety Filter のみ | 入力/出力 Guardrail + PIIマスキング + 業務ルール検証 + 監査ログ |
| 手動確認 | 継続評価バッチ（BigQuery + Vertex AI Evaluation + Looker） |

---

## 7. リスク・注意点・得られた知見

### 実装上ハマった点

- **Gemini 応答の揺れ**: `response_mime_type: application/json` 指定で JSON 確定。フォールバック正規表現パーサも組込
- **max_output_tokens**: 2048では不足（途中で切れてJSON壊れる）。**8192** に設定
- **モデルID**: 2026-04時点で `gemini-1.5-flash-002` は退役。`gemini-2.5-flash` を使用
- **vertexai SDK 廃止予定**: 2026-06-24で `vertexai.generative_models` が削除予定。将来的に `google-genai` へ移行が必要
- **macOS ローカル gunicorn fork 問題**: `functions-framework` CLI で gRPC の Objective-C fork 問題。対策としてローカルテストは `test_local.py` で直接関数呼出（Linux本番環境では発生せず）
- **FlexiPage の mode 指定**: 親テンプレートの領域を上書きする Facet には `<mode>Replace</mode>` が必要（カスタム Facet には不要）
- **Salesforce 日本語選択リスト値**: CLAUDE.md ルールで `Priority__c` 等は「高/中/低」の日本語値

### エージェント特有の問題と対策

- **ツール呼び忘れ**: `write_*` ツールを Gemini が呼ばないことがある。system_instruction で「最後に必ず呼ぶこと」を強く指示
- **配列応答**: 複数ニーズ入力時に Gemini が配列で返すことがある。パーサで先頭要素を自動採用 + プロンプトで「1つのJSONオブジェクトにまとめよ」を明示
- **ツール引数の型**: Function Calling の仕様上、原始型（string/number/enum）しか使えない。複雑な構造は辞書の value として渡す
- **tool_history の配列順序**: Gemini の並列 function_call 対応により同時に複数呼出される可能性があり、iteration 内で配列として処理

### 運用上の知見

- **Vertex AI レイテンシは変動**: 通常30秒のところ78秒〜180秒超に伸びる日がある（Gemini 側の負荷）。Cloud Functions timeout は余裕を持って設定（現行300秒）
- **429 レート制限**: Vertex AI のデフォルト RPM は低い。本番では Quota 増枠リクエストが必要。エージェント側に指数バックオフリトライ実装済
- **min-instances=1** でコールドスタート回避。月額約 ¥800 程度でデモ用途なら許容範囲
- **Cloud Functions への HTML 同梱**: `/trigger` でHTMLページを返す構成。CORS 不要、管理がシンプル

### セキュリティ設計の簡略化（デモ限定）

- `allow-unauthenticated` で公開（本番では IAM 認証 + Apigee 推奨）
- SF→GCP は Remote Site Setting + TLS のみ（本番では mTLS + VPC Service Controls）
- JWT 秘密鍵を環境変数にべた置き（本番では Secret Manager）
- VPC Service Controls 未設定（本番では必須、特に機密な設計図面を扱う場合）

---

## 8. 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-04-12 | 初版作成。UI/UX決定、実装ステップ定義、シナリオ1（固定パイプライン）完成 |
| 2026-04-12 | LWC配置先を Needs_Card__c → Product_Initiative__c に変更。Initiative + 複数ニーズ対応 |
| 2026-04-13 | GCS Signed URL 生成 + LWC インラインプレビュー実装 |
| 2026-04-13 | ニーズ分析ダッシュボードV2（Trust Layer バイパス版）追加 |
| 2026-04-14 | シナリオ2（Product Engineering Agent）着手・完成。Equipment_Alert__c、HTMLトリガー、LWC 一式 |
| 2026-04-14 | A-1000 シナリオ追加、検知値編集UI、5ステップ進捗演出、tool_history表示 |
| 2026-04-15 | シナリオ1 エージェント化完了。統一エージェント10ツール体制に移行 |
| 2026-04-15 | Imagen 3.0 で製品写真生成、assetShowcaseGcp LWC 追加（地図 + 画像） |
| 2026-04-16 | Cloud Functions timeout 180→300秒。ドキュメント全体整理（本書含む） |
