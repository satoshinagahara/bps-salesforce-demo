# GCP 連携構築ログ — Vertex AI マルチモーダル × Salesforce 製品改善提案

> **目的**: 製品施策 × 顧客ニーズ × GCP Vertex AI Gemini マルチモーダル × Salesforce書き戻し のデータパイプラインを構築する
> **設計書**: [gcp_demo_design_concept.md](../concepts/gcp_demo_design_concept.md)

---

## 0. 確定済みUI/UX決定事項

| 論点 | 決定 | 理由 |
|---|---|---|
| 配置先 | **Product_Initiative__c（製品施策）レコードページ** FlexiPage12 | ビジネス意思決定と技術提案の交差点 |
| エントリーポイント | FlexiPage12 に新規タブ「製品改善提案 by GCP」 | SFとGCPの境界が明示的 |
| 処理中表示 | 4ステップのプログレス表示（CSSスピナー） | パイプラインの可視化。オーバーレイなし |
| 結果表示 | タブ内にインライン＋軽いスライドイン＋**参照資料プレビュー** | Geminiが参照したPDF/図面が画面上で見える |
| 入力プレビュー | ボタン前に**施策情報（Why/What）+ 紐付くニーズカード一覧**をプレビュー | 「何がGCPに渡るか」を画面で明示 |
| 履歴 | 毎回新規生成のみ | 収録用シンプル優先 |

### データパイプライン設計変更の経緯（ニーズカード→製品施策へ移動）

当初はニーズカード（Needs_Card__c）レコードページにGCP連携タブを配置していたが、以下の理由で製品施策（Product_Initiative__c）に移動した：

1. **ビジネスと技術の交差**: 製品施策はビジネスサイドの意思決定（Why/What/Who）が集約されるレコード。ここにGCPの技術提案を返すことで、ビジネスの意思と技術の具体策が合流する
2. **入力情報の豊かさ**: 製品施策には施策の Why/What/ターゲット顧客像 + Initiative_Need__c 経由で**複数のニーズカード**が紐付く → Geminiへの入力が格段に豊かになる
3. **パイプラインの一貫性**: 「面談メモ → ニーズ構造化 → ターゲッティング → 製品施策（ビジネス意思決定）→ GCPが技術的な裏付けを返す」という一本道のデータパイプラインが成立

---

## 1. アーキテクチャ全体像

### 1.1 Salesforce 側データパイプライン

```
面談記録 → ニーズカード → ターゲッティングLWC → 製品施策（Product_Initiative__c）
 (Meeting)   (Needs_Card)  (initiativeNeedsMatcher)  ├─ Why: なぜやるか
                                                      ├─ What: 何をするか
                                                      ├─ Who: ターゲット顧客像
                                                      ├─ Product: 対象製品
                                                      └─ [タブ] 製品改善提案 by GCP ← ★ここ
                                                           ↕ GCP連携
```

### 1.2 SF ↔ GCP 連携アーキテクチャ

```
┌──────────────────────────────────────────────────────────────────┐
│ Salesforce (BPS デモ org)                                         │
│                                                                   │
│  Product_Initiative__c Record Page (FlexiPage12)                 │
│   └─ [タブ] 製品改善提案 by GCP                                   │
│       └─ LWC: designSuggestionGcp                                │
│           ├─ 施策プレビュー（Why/What/Who + 対象製品）             │
│           ├─ 紐付くニーズカード一覧（Initiative_Need__c経由）     │
│           ├─ ボタン「GCP 製品改善提案を生成」                     │
│           ├─ 4ステップ進捗表示（CSSスピナー、オーバーレイなし）    │
│           ├─ 結果カード（スライドイン）                            │
│           └─ 参照資料プレビュー（仕様書PDF + 図面PNG）             │
│                │                                                  │
│                │ imperative Apex                                  │
│                ▼                                                  │
│  Apex: DesignSuggestionGcpController                             │
│   ├─ getPreviewData(initiativeId) @wire                          │
│   │    → Initiative + Initiative_Need__c → Needs_Card__c 取得    │
│   └─ generateDesignSuggestion(initiativeId) imperative           │
│        → HTTP Callout via Remote Site Setting                    │
│                │                                                  │
└────────────────┼──────────────────────────────────────────────────┘
                 │
                 │ HTTPS POST (JSON: { initiativeId, initiativeTitle,
                 │   whyRationale, whatDescription, targetCustomer,
                 │   productName, linkedNeeds: [...] })
                 ▼
┌──────────────────────────────────────────────────────────────────┐
│ GCP Project: ageless-lamp-251200 (表示名: bps-demo-project)      │
│                                                                   │
│  Cloud Functions Gen2 (Python 3.12, asia-northeast1)             │
│  generate-design-suggestion                                      │
│   ├─ ① 施策 + ニーズデータ受信                                    │
│   ├─ ② Cloud Storage から仕様書PDF・図面PNG取得                   │
│   ├─ ③ Vertex AI Gemini 2.5 Flash マルチモーダル呼出             │
│   │    （テキスト × PDF × PNG を同時処理）                         │
│   ├─ ④ GCS Signed URL 生成（PDF/PNG プレビュー用）               │
│   ├─ ⑤ Salesforce REST API で DesignSuggestion__c 書き戻し       │
│   │    （JWT Bearer Flow 認証）                                   │
│   └─ ⑥ レスポンス返却（提案JSON + Signed URL）                   │
│                                                                   │
│  Cloud Storage: gs://bps-design-assets (asia-northeast1)         │
│   ├─ specs/bps_spec_wind_turbine_a1000.pdf (5p, 478KB)           │
│   └─ diagrams/blade_pitch_control_diagram.png (91KB)             │
│                                                                   │
│  Vertex AI: Gemini 2.5 Flash (us-central1)                       │
└──────────────────────────────────────────────────────────────────┘
```

### 1.3 実装方針

- LWC → Apex → Cloud Functions → (Gemini + GCS + Signed URL + SF書き戻し) → Apex → LWC の往復構造
- Cloud Functions が Salesforce に書き戻す（GCP主導の連携感を演出）
- Cloud Functions が GCS Signed URL を生成してレスポンスに含める → LWC が仕様書PDF/図面PNGをインライン表示（マルチモーダル処理の証拠を可視化）
- 複数ニーズが入力されてもGeminiは1つの統合提案を返す（プロンプトで制御）

---

## 2. Salesforce側の実装 ✅ 完了

### 2.1 カスタムオブジェクト: `DesignSuggestion__c`（製品改善提案）✅

**オブジェクトラベル**: **製品改善提案**
**配置先**: Product_Initiative__c（製品施策）レコードページ

| API名 | 型 | ラベル | 備考 |
|---|---|---|---|
| `Name` | AutoNumber | 提案番号 | `DS-{0000}` |
| `Initiative__c` | Lookup(Product_Initiative__c) | 製品施策 | **主要な親レコード** |
| `NeedsCard__c` | Lookup(Needs_Card__c) | 元ニーズカード | 任意（下位互換用） |
| `TargetProduct__c` | Text(255) | 対象製品 | Geminiが推論 |
| `TargetComponent__c` | Text(255) | 対象コンポーネント | — |
| `SuggestionText__c` | LongTextArea(32768, 8行) | 提案本文 | — |
| `ReferenceSpec__c` | Text(255) | 参照仕様書 | 仕様書セクション番号 |
| `ReferenceDiagram__c` | Text(255) | 参照図面 | 図面ファイル名 |
| `Priority__c` | Picklist | 優先度 | 高/中/低（日本語値） |
| `ProcessedBy__c` | Text(100) | 生成AI | 「Vertex AI gemini-2.5-flash」 |
| `GeneratedAt__c` | DateTime | 生成日時 | — |
| `GcpRequestId__c` | Text(64) | GCPリクエストID | トレース用 |

**FLS**: ✅ `BOM_Full_Access` にオブジェクト+全フィールド権限追加済み

### 2.2 Apexクラス: `DesignSuggestionGcpController` ✅

**製品施策起点**に変更済み。主要メソッド：
- `getPreviewData(Id initiativeId)` — 施策情報 + Initiative_Need__c経由でニーズカード一覧を取得
- `generateDesignSuggestion(Id initiativeId)` — 施策+ニーズをGCPに送信、結果をDTOで返却
- DTOに `specUrl` / `diagramUrl`（Signed URL）を含む

### 2.3 外部接続: Remote Site Setting ✅

- Named Credentialではなく既存パターンに合わせて**Remote Site Setting**を使用
- `GCP_Design_Suggestion`: `https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net`

### 2.4 LWC: `designSuggestionGcp` ✅

**配置先**: FlexiPage12（Product_Initiative__c レコードページ）の3番目のタブ

**UI構成**:
1. **施策プレビュー**: Why/What/ターゲット顧客像/対象製品
2. **紐付くニーズカード一覧**: チップ表示（タイトル + 顧客名）
3. **GCP情報バー**: 「施策の意図 × 顧客ニーズ × 仕様書PDF × 図面 → Vertex AI Gemini でマルチモーダル照合」
4. **生成ボタン**: 「GCP 製品改善提案を生成」
5. **4ステップ進捗**: CSSスピナー（オーバーレイなし）
6. **結果カード**: スライドイン（対象製品/コンポーネント/提案本文/参照/優先度）
7. **参照資料プレビュー**: Cloud Storage の図面PNG + 仕様書PDF をインライン表示（GCS Signed URL）

### 2.5 CSP Trusted Site ✅

- `GCS_Storage`: `https://storage.googleapis.com`（img-src, frame-src, connect-src 許可）

### 2.6 Connected App ✅

- `GCP_Design_Suggestion`（Consumer Key/Secret 取得済み）
- GCP→SF認証は JWT Bearer Flow（sf CLIの既存 server.key を流用）
- `isGenerating` — ボタン活性制御
- `showResult` — スライドイン演出トリガー

**4ステップの見せ方**（収録時にナレーションと同期しやすい設計）:
| # | ラベル | 実態 |
|---|---|---|
| ① | Salesforce → GCP へニーズ送信 | Apex Callout 開始直前 |
| ② | Cloud Storage から仕様書PDF・図面を取得 | Cloud Functions側のステップ（ダミー時間挿入可） |
| ③ | Vertex AI Gemini マルチモーダル処理中 | Gemini API 呼出中 |
| ④ | 設計示唆を Salesforce へ書き戻し | DesignSuggestion__c insert |

> **実装トリック**: Cloud Functionsから「進捗」をリアルタイムに取る必要はない。LWC側でステップを一定間隔（例: 800ms）で進めつつ、Apexの結果が返ってきたら④を完了→結果カードをスライドインする。動画収録なので実時間との厳密な同期は不要。

**CSS演出**: 結果カードは `transform: translateY(20px); opacity: 0` から `translateY(0); opacity: 1` への transition（400ms）

### 2.5 FlexiPage9への新規タブ追加

既存の2タブ（detailTab / relatedListsTab）に3つ目を追加:
```xml
<itemInstances>
  <componentInstance>
    <componentInstanceProperties>
      <name>body</name>
      <value>...Facet参照...</value>
    </componentInstanceProperties>
    <componentInstanceProperties>
      <name>title</name>
      <value>設計示唆 by GCP</value>
    </componentInstanceProperties>
    <componentName>flexipage:tab</componentName>
    <identifier>designSuggestionGcpTab</identifier>
  </componentInstance>
</itemInstances>
```
Facet内に `c:designSuggestionGcp` を配置。

---

## 3. GCP側の実装

### 3.1 プロジェクト構成

| 項目 | 値 |
|---|---|
| Project 表示名 | `bps-demo-project` |
| **Project ID（実ID）** | **`ageless-lamp-251200`** |
| Project Number | `174999106767` |
| Billing Account | `010067-E62B2B-D634F6`（有効） |
| リージョン | `asia-northeast1`（Cloud Functions/Storage）/ `us-central1`（Vertex AI） |
| 有効化API | Cloud Functions, Cloud Build, Cloud Run, Artifact Registry, Vertex AI (aiplatform), Eventarc, IAM Credentials, Cloud Logging, Cloud Storage 等 |

> ⚠️ `bps-demo-project` は表示名。gcloudコマンドでは必ず `ageless-lamp-251200` を使うこと。

### 3.2 サービスアカウント（作成済み）

- 名前: `bps-demo-sa@ageless-lamp-251200.iam.gserviceaccount.com`
- 表示名: `BPS Demo Service Account`
- 付与済みロール（2026-04-12 確認）:
  - ✅ `roles/aiplatform.user` (Vertex AI)
  - ✅ `roles/storage.objectViewer` (GCS 読み取り)
  - ✅ `roles/logging.logWriter`
- 用途: Cloud Functions Gen2 の実行アイデンティティとしてアタッチ予定

### 3.3 Cloud Storage バケット

- バケット名: `bps-design-assets`（グローバル一意化のため必要に応じて `bps-design-assets-<suffix>`）
- ロケーション: `asia-northeast1`
- 格納物:
  - `specs/BPS_spec_wind_turbine_A1000.pdf` — 風力タービン仕様書（自作3ページ）
  - `specs/BPS_spec_battery_E2000.pdf` — 蓄電システム仕様書（シーン2用、今回は未使用だが置いておく）
  - `diagrams/blade_pitch_control_diagram.png` — ブレードピッチ制御模式図

### 3.4 Cloud Functions: `generate-design-suggestion`

**言語**: Python 3.11 / Cloud Functions Gen2 / functions-framework

**ディレクトリ構成** (Salesforceプロジェクト外。別リポジトリまたは同リポジトリの `gcp/` 配下):
```
gcp/generate-design-suggestion/
  main.py
  requirements.txt
  .env.yaml (非コミット)
  .gcloudignore
```

**リクエスト仕様**:
```json
POST /
{
  "needsCardId": "a00...",
  "title": "低風速域での発電効率向上の要望",
  "customerVoice": "...",
  "description": "...",
  "productName": "A-1000 大型風力タービン",
  "accountName": "BPS Wind Farms Inc."
}
```

**レスポンス仕様**:
```json
{
  "designSuggestionId": "a01...",
  "targetProduct": "A-1000 大型風力タービン",
  "targetComponent": "ブレード角度制御機構",
  "suggestionText": "...",
  "referenceSpec": "BPS_spec_wind_turbine_A1000.pdf (P.3)",
  "referenceDiagram": "blade_pitch_control_diagram.png",
  "priority": "高",
  "processedBy": "Vertex AI Gemini 1.5 Flash",
  "generatedAt": "2026-04-12T10:23:45+09:00",
  "gcpRequestId": "req_abc123"
}
```

**内部処理フロー**:
1. リクエストバリデーション
2. GCSから仕様書PDF (bytes) + 図面PNG (bytes) を取得
3. Vertex AI `GenerativeModel('gemini-1.5-flash')` にマルチモーダル入力で呼出
   - Part 1: テキスト（ニーズ情報 + システムプロンプト）
   - Part 2: PDF（inline_data, mime_type=application/pdf）
   - Part 3: PNG（inline_data, mime_type=image/png）
4. レスポンスをJSON構造にパース（Geminiに構造化出力を指示）
5. Salesforce REST API (`/services/data/v62.0/sobjects/DesignSuggestion__c`) にPOST
   - 認証: JWT Bearer Flow（サービスアカウント秘密鍵 + Connected App）
6. 作成されたレコードIDをレスポンスに含めて返す

### 3.5 Vertex AI プロンプト設計

**システムプロンプト** (text part):
```
あなたは再生可能エネルギー機器メーカー BPS Corporation の製品設計アドバイザーです。
営業が収集した顧客ニーズと、添付の製品仕様書PDFおよび図面画像を照合し、
具体的な製品エンハンス提案を生成してください。

出力は以下のJSON形式で、他のテキストは含めないでください：
{
  "targetProduct": "対象製品名",
  "targetComponent": "対象コンポーネント名",
  "suggestionText": "設計示唆本文（3〜5行）",
  "referenceSpec": "参照した仕様書の該当ページ",
  "referenceDiagram": "参照した図面ファイル名",
  "priority": "高" | "中" | "低"
}
```

**ユーザープロンプト** (text part):
```
以下の顧客ニーズに対して、添付の仕様書・図面を参照しながら、
どの製品のどの部分をどう改善すればよいか提案してください。

【顧客】{accountName}
【対象製品】{productName}
【ニーズタイトル】{title}
【顧客の声】{customerVoice}
【詳細】{description}
```

### 3.6 Salesforce Connected App (GCP → Salesforce 認証) ✅ 作成済み

- Connected App名: `GCP Design Suggestion Integration`（API参照名: `GCP_Design_Suggestion`）
- 作成日: 2026-04-12
- Consumer Key: `3MVG9RcRPG0Y85btiQ0UVggA23_T2u6epT8W_bXH2DuQj78uVCB.5Zwaun4ZiAYcO.waOFrUi0QqTQ0qoJ4oS`
- OAuth Scopes: `api`, `refresh_token`, `offline_access`
- IP制限: BYPASS（IP制限の緩和）

**認証方式（実装済み）**: 2段階フォールバック
1. 環境変数 `SF_ACCESS_TOKEN` が設定されていればそのまま使用（テスト/デモ用）
2. `SF_PRIVATE_KEY_B64` + `SF_CONSUMER_KEY` + `SF_USERNAME` が設定されていれば **JWT Bearer Flow** で自動トークン取得
   - sf CLI で既に利用している `server.key` をbase64エンコードしてCloud Functionsの環境変数に格納する想定
   - sf CLIの既存Connected App（consumer_key: `3MVG9RcRPG...R2gH`）をJWT認証に流用可能

**備考**: 当初 Client Credentials Flow を検討したが、デモorgの「接続アプリケーションの編集」画面にClient Credentials有効化オプションが表示されなかったため、JWT Bearer Flow + アクセストークン直指定のフォールバック方式を採用

---

## 4. サンプル資産の準備 ✅ 完了

### 4.1 仕様書PDF ✅

- **ファイル**: `gcp/assets/specs/bps_spec_wind_turbine_a1000.pdf`（5ページ, 478KB）
- **GCS**: `gs://bps-design-assets/specs/bps_spec_wind_turbine_a1000.pdf`
- **生成方法**: Markdown → Pandoc(HTML) → weasyprint(PDF)
- **ソースファイル**: `gcp/assets/specs/bps_spec_wind_turbine_a1000.md` + `spec_style.css`
- **仕込み**: P.3(PDF上P.4) §3.2で「起動モード3.5-5.0m/sは発電効率最適化の対象外」と明記。P.3(PDF上P.5) §3.4で既知の設計課題として低風速域の翼角度制御パラメータ未最適化を記載 → Geminiがこのギャップを検出して改善提案を生成する

### 4.2 図面PNG ✅（プレースホルダ）

- **ファイル**: `gcp/assets/diagrams/blade_pitch_control_diagram.png`（91KB）
- **GCS**: `gs://bps-design-assets/diagrams/blade_pitch_control_diagram.png`
- **生成方法**: Python(Pillow)で自動生成（`gcp/assets/diagrams/generate_placeholder.py`）
- **状態**: C-3プレースホルダ（白背景＋テキストラベル＋簡易図形）。後半でC-2（Excalidraw等で描いた実図面）に差し替え予定

### 4.3 シード用ニーズカードデータ 🔲 未作成

デモ専用のNeeds_Card__cレコードを新規作成する必要あり（風力タービン×低風速域のニーズ）。現在のテストでは既存レコード `NC-0500`（a3BIe000000DJBQMA4）を使用

---

## 5. 実装ステップ（進捗）

| # | ステップ | 状態 | 完了日 | 備考 |
|---|---|---|---|---|
| 1 | GCPプロジェクト初期化 | ✅ | 2026-04-12 | gcloud CLI + API有効化 + SA作成 |
| 2 | サンプル資産作成 | ✅ | 2026-04-12 | PDF(5p, weasyprint) + ダミーPNG(Pillow) |
| 3 | Cloud Storage バケット作成＋アップロード | ✅ | 2026-04-12 | gs://bps-design-assets (2ファイル) |
| 4-5 | Cloud Functions + Vertex AI | ✅ | 2026-04-12 | gemini-2.5-flash、Signed URL対応 |
| 6 | DesignSuggestion__c 作成 | ✅ | 2026-04-12 | ラベル「製品改善提案」+ Initiative__c Lookup追加 |
| 7 | Connected App + JWT認証 | ✅ | 2026-04-12 | server.key B64化、CF環境変数に設定 |
| 8 | SF書き戻し実装 | ✅ | 2026-04-12 | Initiative__c / NeedsCard__c 両対応 |
| 9 | Remote Site Setting | ✅ | 2026-04-12 | GCP_Design_Suggestion |
| 10 | Apex Controller | ✅ | 2026-04-12 | 製品施策起点に変更。Initiative + Initiative_Need__c 経由でニーズ取得 |
| 11 | LWC designSuggestionGcp | ✅ | 2026-04-12 | 施策プレビュー + ニーズチップ + 4ステップ + 結果カード + 参照資料プレビュー |
| 12 | FlexiPage12 タブ追加 | ✅ | 2026-04-12 | Product_Initiative__c ページに「製品改善提案 by GCP」タブ |
| — | CSP Trusted Site | ✅ | 2026-04-12 | storage.googleapis.com (img/frame/connect) |
| — | BOM_Full_Access 権限セット | ✅ | 2026-04-12 | オブジェクト+12フィールド+Apexクラス |
| — | E2Eテスト（製品施策ページ） | ✅ | 2026-04-12 | 「次世代静音型タービン性能強化」施策 × 3ニーズカードで動作確認 |
| — | デモ用ニーズカード紐付け | ✅ | 2026-04-12 | NC-0448/0447/0435 → 次世代静音型タービン施策 |
| — | ダミー図面 → 実図面差し替え | 🔲 | — | C-2（Excalidraw等）で差し替え予定 |
| — | デモ専用ニーズカード作成 | 🔲 | — | 風力タービン×低風速域の専用レコード |
| — | 動画収録リハーサル | 🔲 | — | — |

---

## 6. リスク・注意点・得られた知見

- **Gemini応答の揺れ**: `response_mime_type: application/json` 指定で JSON 確定。フォールバック正規表現パーサもmain.pyに組込済
- **max_output_tokens**: 2048では不足（途中で切れてJSON壊れる）。**4096必須**（反映済）
- **モデルID**: 2026-04時点で `gemini-1.5-flash-002` は退役。**`gemini-2.5-flash`** を使用（反映済）
- **vertexai SDK 廃止予定**: 2026-06-24で `vertexai.generative_models` が削除。`google-genai` SDK への移行が必要（将来タスク）
- **macOS ローカル gunicorn fork問題**: `functions-framework` CLI で起動するとgRPCのObjective-C fork()問題でワーカーがSIGKILLされる。`OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` では不十分。**対策**: ローカルテストは `test_local.py` で直接 `_call_gemini()` を呼び出す方式に切替。Cloud Functions本番環境(Linux)では発生しない
- **レイテンシ**: デプロイ後実測で12.7秒（コールドスタート含む）。LWC側の4ステップ進捗表示で体感を和らげる
- **Cloud Functions コールドスタート**: 収録前に1回ウォームアップを叩いておく
- **JWT Bearer認証の初期設定**: 証明書生成・Connected App設定が一度ハマると時間を食う。ここだけ別セクションで丁寧に進める
- **リージョン**: Vertex AIは `us-central1`、Cloud Functions は `asia-northeast1` のクロスリージョン構成。数百msのレイテンシ差は許容範囲
- **選択リスト日本語値**: `Priority__c` の値は「高/中/低」の日本語（CLAUDE.mdルール）

## 6.5 実装完了済みリソース（Step 4-5 時点）

| リソース | 値 |
|---|---|
| Cloud Function URL | `https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion` |
| Cloud Run URI (内部) | `https://generate-design-suggestion-7lvftppqya-an.a.run.app` |
| ランタイム | Python 3.12 |
| メモリ | 1 GiB |
| タイムアウト | 120秒 |
| リビジョン | `generate-design-suggestion-00001-rup` |
| モデル | `gemini-2.5-flash` |
| 実測レイテンシ（初回） | 約12.7秒 |

---

## 7. 未決・後で詰める項目

- [ ] 論点4: GCP感の演出詳細（バッジ色、「Processed by Vertex AI Gemini」ロゴの出し方）
- [ ] 論点5: 結果カードの情報粒度最終形（項目の追加・削除）
- [ ] 論点6: 動画上のシーン1-A→1-Bの遷移演出
- [ ] サンプルPDFの具体的な文面・図面の具体的な絵柄
- [ ] デモ用ニーズカードのAccount/Product紐付け先（既存マスタ流用 or 新規作成）
- [ ] 収録台本（ナレーション稿）

---

## 8. 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-04-12 | 初版作成（UI/UX決定を反映、実装ステップ定義） |
| 2026-04-12 | Step 1-8 完了: GCPバックエンド全構築完了（Cloud Functions + Vertex AI gemini-2.5-flash + SF書き戻し）|
| 2026-04-12 | Step 9-12 完了: SF UI側完成。**アーキテクチャ変更**: LWC配置先をNeeds_Card__c→Product_Initiative__c（製品施策）に移動。ビジネス意思決定と技術提案の交差点を製品施策レコード上に実現。Apex Controllerを製品施策起点に書換（Initiative + Initiative_Need__c経由で複数ニーズ取得）。GCS Signed URL生成を追加し、LWC上で仕様書PDF/図面PNGのインラインプレビューを実現。CSP Trusted Site追加。Cloud Functions rev 00007（max_output_tokens=8192、配列応答耐性、Initiative対応プロンプト） |
