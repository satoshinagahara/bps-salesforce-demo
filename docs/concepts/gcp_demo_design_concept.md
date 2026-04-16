# BPS デモ設計仕様書
## Salesforce × GCP 連携デモ — 設計コンセプト

> ### ⚠️ 実装による変更（2026-04-12）
>
> 本書は構想段階の設計仕様書です。実装の過程で以下の重要な変更が発生しました。
> **最新の実装状態は [gcp-demo-build-log.md](../in-progress/gcp-demo-build-log.md) を参照してください。**
>
> #### 主な変更点
> | 項目 | 本書（構想） | 実装後 |
> |---|---|---|
> | **GCP連携の配置先** | ニーズカード（Needs_Card__c）ページ | **製品施策（Product_Initiative__c）ページ** |
> | **入力データ** | 1件のニーズカード | **施策のWhy/What + 複数ニーズカード** |
> | **Vertex AIモデル** | Gemini 1.5 Flash | **Gemini 2.5 Flash** |
> | **認証方式** | JWT Bearer Flow（証明書新規作成） | **JWT Bearer Flow（sf CLI既存server.key流用）** |
> | **参照資料プレビュー** | なし | **GCS Signed URLで仕様書PDF/図面PNGをLWC内にインライン表示** |
> | **シーン2-A（IoT）** | 実装予定 | 未着手（シーン1-Bを先行完成） |
>
> #### 変更の理由
> 製品施策レコードに配置することで「ビジネスサイドの意思決定（Why/What）」と「GCPの技術提案（具体的にどうすべきか）」が同一画面上で交差する構造になった。

---

## 0. 基本方針

### デモの目的
「顧客の一次情報がSoEを軸にGCPで昇華され、
ビジネスアクションに変換されるデータパイプラインの考え方を実証する」

- ツールを見せるのではなくデータパイプラインの考え方を見せる
- 「GCPからSalesforceに何かが届いている」状態を可視化する
- 動画収録前提のため待ち時間・エラーリスクを排除できる
- 役員向けプレゼンとして許容される演出品質を目指す

### 収録方針
- 画面収録ツール（QuickTime / OBS等）で事前収録
- 編集なしの1テイク録りを基本とする（信頼性のため）
- 必要に応じてカット編集を加えても良い
- BGMなし、ナレーションは肉声で重ねる

---

## 1. デモ全体構成

```
シーン1：施策1デモ（約3〜4分）
  ├── 1-A: ニーズカード（Salesforce内 Layer 1）
  └── 1-B: GCP設計示唆連携（Layer 2 追加）

シーン2：施策2デモ（約2〜3分）
  └── 2-A: IoTイベント→SalesforceアラートのGCPパイプライン

合計：5〜7分以内
```

---

## 2. シーン1-A：ニーズカード（Layer 1 / Salesforce完結）

### 目的
面談メモ → AI構造化 → ビジネス示唆という
データパイプラインの「入口」を見せる

### 使用システム
- Salesforce（既存のBPS デモ環境）
- 既実装：ニーズカード機能（25個のPrompt Template含む）

### デモの流れ
```
1. 営業担当者の面談メモを入力（または既存レコードを開く）
2. AIが要素分解・構造化を実行
3. ニーズカードが生成される
   - 顧客課題の構造化
   - 製品カテゴリとの紐付け
   - ビジネスインパクトのスコアリング
4. 商談ロードマップへの示唆が出力される
```

### 画面遷移イメージ
```
商談レコード → 面談メモ入力 → ニーズカード生成
→ 5タブ分析ダッシュボード → 商談ロードマップ示唆
```

### ナレーション骨格（本番で肉声）
```
「営業なら誰でも取っている面談メモです。
 これをAIが要素分解・構造化します。
 重要なのはツールではなく、
 顧客の一次情報がビジネス判断に
 使えるレベルに昇華されるプロセスです。
 ここまでがSalesforce上で完結する部分です。
 次に、GCPが加わることで何が変わるかをご覧ください。」
```

---

## 2. シーン1-B：GCP設計示唆連携（Layer 2）

### 目的
Salesforceのニーズデータ × GCPの設計資産（PLM・仕様書・図面）
→ Vertex AI マルチモーダル処理
→ Salesforceに設計示唆が返ってくる

### 技術アーキテクチャ
```
[Salesforce]
ニーズカードの構造化データ（テキスト）
  ↓ Apex HTTP Callout または Webhook
[Cloud Functions（トリガー）]
  ↓
[Cloud Storage]
  ・製品仕様書サンプル（PDF）
  ・図面サンプル（PNG/JPEG）
  ・過去の設計変更履歴（JSON）
  ↓
[Vertex AI Gemini API]
  ・ニーズテキスト × 仕様書PDF × 図面画像
  ・マルチモーダルプロンプト処理
  ・「どの製品のどの部分をどう変えるべきか」を生成
  ↓
[Cloud Functions（レスポンス整形）]
  ↓ Salesforce REST API
[Salesforce]
  カスタムオブジェクト（設計示唆レコード）に書き戻し
  担当者へのタスク・通知生成
```

### 使用GCPサービス
| サービス | 役割 | コスト感 |
|---------|------|---------|
| Cloud Functions（第2世代） | トリガー・整形 | ほぼ無料枠内 |
| Cloud Storage | 仕様書・図面の保管 | 数円/月 |
| Vertex AI Gemini 1.5 Flash | マルチモーダル処理 | 数円〜数十円/回 |
| Cloud Run（オプション） | API エンドポイント化 | ほぼ無料枠内 |

### デモ用サンプルデータ
```
仕様書サンプル：
- BPS_spec_wind_turbine_A1000.pdf（架空の風力タービン仕様書）
- 内容：出力特性・部品構成・メンテ仕様を含むPDF（2〜3ページ）
- 自作またはダミーデータで作成

図面サンプル：
- component_diagram_blade.png（ブレード部品の模式図）
- 精緻な図面でなくて良い。AI処理が成立することを見せることが目的

ニーズデータ（入力）：
- 「顧客より、低風速域での発電効率向上の要望が強い」
- 「メンテナンス頻度の削減が経営課題として挙がっている」
```

### Vertex AI プロンプト設計（骨格）
```
システムプロンプト：
「あなたは再生可能エネルギー機器メーカーの製品設計アドバイザーです。
 営業が収集した顧客ニーズと製品仕様書・図面を照合し、
 具体的な製品エンハンス提案を生成してください。
 出力は設計チームがすぐにアクションできる形式にすること。」

ユーザープロンプト：
「以下の顧客ニーズに対して、添付の仕様書・図面を参照しながら、
 どの製品のどの部分をどう改善すればよいか提案してください。
 ニーズ：{needs_text}
 仕様書：{pdf_content}
 図面：{image_data}」
```

### Salesforceへの書き戻し先（カスタムオブジェクト案）
```
オブジェクト名：DesignSuggestion__c（設計示唆）
フィールド：
  - NeedsCard__c：紐付けニーズカード
  - SuggestionText__c：GCPが生成した設計示唆テキスト
  - TargetProduct__c：対象製品
  - TargetComponent__c：対象コンポーネント
  - Priority__c：優先度
  - GeneratedAt__c：生成日時
  - ProcessedBy__c：「GCP Vertex AI」（固定値）
```

### 画面遷移イメージ（収録）
```
[Salesforce] ニーズカードレコード
  → 「GCP設計示唆を生成」ボタンをクリック
  → 処理中インジケーター（数秒）
  → 設計示唆レコードが生成される
  → 「対象製品：A-1000 大型風力タービン」
     「対象コンポーネント：ブレード角度制御機構」
     「提案：低風速域の発電効率向上のため
             ピッチ制御アルゴリズムの改善を推奨。
             仕様書P.3の制御仕様と図面の
             アクチュエータ配置を参照。」
  → 設計担当者へのタスクが自動生成される
```

### ナレーション骨格
```
「シーン1-AではSalesforce上でニーズを構造化しました。
 今度はそのデータをGCPに送信します。
 GCPのCloud StorageにはBPS社の製品仕様書と図面が格納されており、
 Vertex AI Geminiがニーズテキストとこれらをマルチモーダルで照合します。
 （設計示唆が届く瞬間を示して）
 GCPからSalesforceに設計示唆が届きました。
 ニーズと仕様書・図面を照合した結果、
 どの製品のどのコンポーネントをどう改善すべきかが
 設計チームにアクションとして届きます。
 これが施策1のデータパイプラインです。」
```

---

## 3. シーン2-A：IoTイベント→Salesforceアラート

### 目的
設備稼働データ（IoT代替）→ GCPで異常検知
→ Salesforceの営業に商談機会アラートが届く

### IoTの代替手法
本物のIoTセンサーなしで実現する方法：

**採用案：手動トリガー型（Cloud Functions HTTP）**
```
メリット：
- デモ収録中に任意のタイミングで発火できる
- 「今センサーが閾値を超えました」という演出が自然
- 複雑なIoTシミュレーターが不要

実装：
- Cloud FunctionsにHTTPエンドポイントを作成
- ブラウザまたはcurlで叩くと一連のパイプラインが動く
- または簡単なHTMLボタンを用意して画面に映す
```

### 技術アーキテクチャ
```
[手動トリガー or Cloud Scheduler]
  センサーデータのJSONサンプルをPublish
  {
    "equipment_id": "E-2000-BPS-001",
    "equipment_name": "EnerCharge Pro 蓄電システム",
    "customer_id": "ACCT-0042",
    "sensor_type": "vibration",
    "value": 8.7,
    "threshold": 7.0,
    "timestamp": "2026-04-15T14:32:00Z",
    "location": "Tokyo Plant B"
  }
  ↓
[Pub/Sub（トピック：equipment-events）]
  ↓
[Cloud Functions（サブスクライバー）]
  異常スコア計算（簡易ロジック：閾値超過判定）
  ※本番ではVertex AIの予兆保全モデルを使用
  ↓
  異常判定 → Salesforce REST API呼び出し
  ↓
[Salesforce]
  ├── Field Service：WorkOrder自動生成
  │   （設備：EnerCharge Pro / 種別：予防保全）
  └── 担当営業のActivityに商談機会アラート生成
      「EnerCharge Pro（ACCT-0042）
       振動値が閾値超過。設備更新の商談機会。
       推奨アクション：3ヶ月以内の提案訪問」
```

### 使用GCPサービス
| サービス | 役割 | コスト感 |
|---------|------|---------|
| Cloud Functions（第2世代） | トリガー・異常判定・SF連携 | ほぼ無料枠内 |
| Pub/Sub | イベントバッファ | 無料枠内 |
| BigQuery（オプション） | サンプル時系列データの表示 | 無料枠内 |

※本番想定アーキテクチャとの違い：
- Bigtable・Dataflow・Vertex AI予兆保全モデルは今回省略
- 異常検知ロジックはCloud Functions内の簡易閾値判定で代替
- 「本番ではVertex AIの予兆保全モデルを使います」とナレーションで補足

### デモ用サンプルデータ
```
設備マスタ（Salesforce上に事前登録）：
- 設備ID：E-2000-BPS-001
- 設備名：EnerCharge Pro 蓄電システム
- 顧客：ACCT-0042（架空の顧客）
- 担当営業：Satoshi N.
- 設置場所：Tokyo Plant B
- 導入年：2021年

センサーデータ（ダミー）：
- 正常時：振動値 3.2〜5.8（閾値7.0）
- 異常時：振動値 8.7（閾値超過）
```

### 画面遷移イメージ（収録）
```
[GCPコンソール or シンプルなHTMLボタン画面]
  「センサーイベント送信」ボタンをクリック
  ↓ 数秒
[Salesforce画面に切り替え]
  担当営業のToday's Tasks / アクティビティを開く
  → 「⚠ 設備アラート：EnerCharge Pro」の通知が出現
  → 「振動値が閾値を超えました。設備更新の商談機会です。」
  → Field ServiceのWorkOrderが生成されている
  → 商談レコードに「設備更新（予防保全起因）」が作成されている
```

### ナレーション骨格
```
「施策1では人が収集した一次情報を活用しました。
 施策2では設備が自動的に生成する一次情報を活用します。
 （ボタンクリックを画面に映しながら）
 今センサーが閾値を超えました。
 このイベントがGCPのPub/Subに届き、
 Cloud Functionsが異常を判定してSalesforceに連携します。
 （Salesforce画面に切り替え）
 担当営業のアクティビティに商談機会アラートが届きました。
 Field ServiceのWorkOrderも自動生成されています。
 本番環境ではVertex AIの予兆保全モデルが
 より精度の高い異常検知を行いますが、
 『GCPが設備の状態を営業のアクションに変換する』
 というパイプラインの考え方はこの通りです。」
```

---

## 4. 実装優先順位

```
Priority 1（必須）：
  シーン1-A（既存のBPSデモ環境をそのまま使う）
  → 追加実装なし、収録のみ

Priority 2（推奨）：
  シーン2-A（Cloud Functions + Pub/Sub + SF REST API）
  → 実装難易度：中
  → 所要時間：2〜4時間
  → コスト：ほぼゼロ

Priority 3（加点要素）：
  シーン1-B（Vertex AI マルチモーダル + SF書き戻し）
  → 実装難易度：中〜高
  → 所要時間：4〜8時間
  → コスト：数百円以内
  → 技術的インパクトは最大
```

---

## 5. 収録・演出方針

### 収録環境
```
- 画面収録：QuickTime（Mac）or OBS
- 解像度：1920x1080推奨
- ブラウザ：Google Chrome（ログアウト状態で整理）
- 事前準備：ブックマークバー非表示・通知オフ
```

### 演出の注意点
```
- URLバーにlocalhost等が映らないよう注意
- 個人情報・実顧客名が映らないよう事前確認
- GCPコンソールのプロジェクト名をBPS関連に設定しておく
- Salesforceの画面はBPS Corporationのデータのみ表示
- 処理待ち時間は動画編集でカットしてOK
```

### デモ当日の使い方
```
- 画面共有で動画ファイルを全画面再生
- ナレーションは肉声でリアルタイムに重ねる
- 動画再生中も聴衆の反応を見て
  ナレーションのスピードを調整する
- 動画終了後にQ&Aを受ける
```

---

## 6. 技術的な注意点・リスク

### Salesforce REST API認証
```
- Connected App を事前に設定
- OAuth 2.0 JWT Bearer Flow を推奨
  （デモ用クレデンシャルをCloud Functionsの環境変数に設定）
- セキュリティ：デモ専用ユーザーを作成・権限を最小化
```

### Vertex AI APIの注意点
```
- プロジェクトでVertex AI APIを有効化
- サービスアカウントにroles/aiplatform.userを付与
- Gemini 1.5 Flash推奨（コスト低・速度高）
- リージョン：us-central1（最も安定）
```

### 失敗時のフォールバック
```
万が一本番で動画再生が失敗した場合：
- スクリーンショットをスライドに埋め込んでおく
- 「動作結果はこちらです」として静止画で説明
- ナレーションで補完できるよう準備する
```

---

## 7. Claude Codeへの引き渡し指示

### 実装依頼の順序
```
Step 1：シーン2-A（優先）
  Cloud Functions（Python 3.11）
  - HTTPトリガー：センサーイベントJSON受信
  - Pub/Sub Publish処理
  - Pub/Sub Subscribe処理（または直接処理）
  - 簡易異常検知ロジック（閾値判定）
  - Salesforce REST API連携（WorkOrder・Activity作成）

Step 2：シーン1-B（次点）
  Cloud Functions（Python 3.11）
  - Salesforceからのニーズデータ受信
  - Cloud Storageからサンプルファイル取得
  - Vertex AI Gemini API呼び出し（マルチモーダル）
  - Salesforceへの設計示唆書き戻し
```

### 共通の実装方針
```
- 言語：Python 3.11
- フレームワーク：Cloud Functions第2世代（functions-framework）
- 認証：サービスアカウント（環境変数でキー管理）
- ログ：Cloud Logging（print文でOK）
- エラーハンドリング：デモ用なので最低限でOK
- コード品質：動けばよい。本番品質は不要。
```

### 環境変数（.env.example）
```
# GCP
GCP_PROJECT_ID=bps-demo-project
PUBSUB_TOPIC_ID=equipment-events
GCS_BUCKET_NAME=bps-design-assets

# Salesforce
SF_INSTANCE_URL=https://xxxxx.salesforce.com
SF_CLIENT_ID=xxxxx
SF_PRIVATE_KEY_PATH=./sf_private_key.pem
SF_USERNAME=demo@bps.example.com

# Vertex AI
VERTEX_AI_LOCATION=us-central1
VERTEX_AI_MODEL=gemini-1.5-flash-001
```

---

## 7.5 Product Engineering Agent アーキテクチャ

### 設計原則

製品エンジニアリングに関わるAI処理を、用途別に独立したCloud Functionsで実装するのではなく、**1つの統一「Product Engineering Agent」に集約**する。エージェントは Vertex AI Gemini Function Calling で実装し、ツール呼出により動的に必要な情報を取得・処理する。

本デモではすでに **2つのユースケース（設計改善提案・IoT設備異常診断）が同じエージェント・同じツール基盤で動作する**構成を実現している。将来のユースケース追加（製品仕様問い合わせ、故障原因調査等）はツール追加だけで対応可能。

### 7.5.1 エージェントが扱うユースケース

| ユースケース | トリガー | 入口 | 状態 |
|---|---|---|---|
| 設計改善提案（シナリオ1） | 製品施策レコードからの問い合わせ | `POST /design-suggestion-agent` | ✅ 実装済 |
| 設備異常診断（シナリオ2） | IoTイベントの到着 | `POST /equipment-alert` | ✅ 実装済 |
| 製品仕様問い合わせ | 営業からのチャット質問 | 将来 | 🔲 |
| 故障原因調査 | 不具合報告の登録 | 将来 | 🔲 |

### 7.5.2 現状のエージェント実装詳細

#### ランタイム

```
Cloud Functions Gen2 (Python 3.12, asia-northeast1)
  ├─ generate-design-suggestion (エントリポイント関数)
  └─ product_engineering_agent.py (エージェントコア)
      - Vertex AI Gemini 2.5 Flash (us-central1)
      - system_instruction を用途別に切替
      - 10ツールを FunctionDeclaration として登録
      - ツール呼出ループ (max 15 iterations)
      - マルチモーダル対応（PDF+PNG Part をツール応答と同時送信）
      - ツール呼出履歴 (tool_history) をレスポンスに含める
```

#### 登録済みツール（10個）

| カテゴリ | ツール | 役割 |
|---|---|---|
| **Salesforce 読取（製品施策系）** | `get_initiative_info(initiative_id)` | Product_Initiative__c から Why/What/対象製品を取得 |
| | `get_linked_needs(initiative_id)` | Initiative_Need__c 経由で紐付くニーズカードを取得 |
| **Salesforce 読取（設備系）** | `get_asset_info(asset_id)` | Asset 情報（製品名/顧客/納入価格）を取得 |
| **製品ナレッジ（GCS）** | `get_product_spec(product_name)` | 仕様書 PDF を取得（Geminiへマルチモーダル入力） |
| | `get_product_diagram(product_name)` | 図面 PNG を取得 |
| | `generate_signed_urls(product_name)` | LWCプレビュー用 Signed URL 生成 |
| **業務判断ロジック** | `calculate_severity(value, threshold, sensor_type)` | 重要度（高/中/低）を算出 |
| | `estimate_opportunity(asset_price, severity, sensor_type)` | 想定商談機会金額を算出 |
| **Salesforce 書戻** | `write_design_suggestion(...)` | DesignSuggestion__c レコード作成 |
| | `write_equipment_alert(...)` | Equipment_Alert__c レコード作成 |

#### エージェントの動作フロー例（シナリオ2）

```
POST /equipment-alert { assetId, sensorType, value, threshold, location }
    ↓
Cloud Functions が system_instruction（equipment_alert用）を選択
    ↓
Gemini Chat セッション開始
    ↓
Iteration 1: Gemini → tool_call: get_asset_info(assetId)
  Runtime: SF REST API で Asset 取得 → 結果を Gemini に返す
    ↓
Iteration 2: Gemini → tool_call: get_product_spec(productName)
  Runtime: GCS から PDF bytes 取得 → PDF を Part 化して次 turn で添付
    ↓
Iteration 3: Gemini → tool_call: get_product_diagram(productName)
  Runtime: GCS から PNG bytes 取得 → PNG を Part 化
    ↓
Iteration 4: Gemini → tool_call: calculate_severity(47.5, 45.0, "セル温度")
  Runtime: 簡易閾値計算 → "高" を返す
    ↓
Iteration 5: Gemini → tool_call: estimate_opportunity(180000000, "高", ...)
  Runtime: Asset Price × 係数 → ¥2.7億を返す
    ↓
Iteration 6: Gemini が仕様書+図面+Asset情報から業務的解釈を生成
    ↓
Iteration 7: Gemini → tool_call: write_equipment_alert(...)
  Runtime: SF REST API で Equipment_Alert__c 作成
    ↓
Iteration 8: Gemini が最終応答
    ↓
Response { alertId, iterations, toolHistory, status }
```

#### 設計上の工夫

| 工夫 | 理由 |
|---|---|
| **統一エージェント + モード別 system_instruction** | ツール基盤を共有しつつ、用途別の語り口・手順指示を使い分け可能 |
| **ツール引数は原始型のみ**（string/number/enum） | Gemini の Function Calling 仕様に素直。複雑な構造は辞書の value として渡す |
| **マルチモーダル Part をツール応答に添付** | PDF/PNG を取得したタイミングで次 turn に渡すことで、Gemini が逐次的に資料を参照可能に |
| **tool_history を返却** | フロントエンドで「エージェントが実際に何をしたか」を表示可能にし、ブラックボックス性を解消 |
| **JWT Bearer Flow による SF 認証** | sf CLI 既存の server.key を base64 化して Cloud Functions の環境変数に格納 |
| **429 リトライ** | Vertex AI のレート制限に対して最大3回、指数的バックオフでリトライ |

### 7.5.3 本番アーキテクチャへの発展

本番運用では以下の観点で発展させる必要がある。

#### (A) マルチエージェント化

現状の Product Engineering Agent は設計改善・異常診断に特化。本番では**業務領域ごとにエージェントを分割**し、必要に応じて連携させる構成が望ましい。

```
[オーケストレーター Agent]
  ├─ Product Engineering Agent ← 現在の実装
  │   - 製品仕様・図面照合
  │   - 設計改善提案
  │   - 異常診断
  │
  ├─ Sales Agent
  │   - 商談ステージ管理
  │   - 提案書ドラフト生成
  │   - 価格交渉サポート
  │
  ├─ Field Service Agent
  │   - WorkOrder 最適割当
  │   - 現場作業員スケジュール
  │   - 修理履歴参照
  │
  └─ Market Intelligence Agent
      - 競合分析
      - 業界トレンド
      - 顧客行動パターン
```

各エージェントは独立デプロイ。オーケストレーターが問い合わせ内容に応じて適切なサブエージェントに委譲する（「この顧客の商談状況と過去の修理履歴を両方踏まえた提案を出して」などに対応可能）。

#### (B) Agent Development Kit (ADK) への移行

現在の Function Calling による実装は**単エージェント・固定ツール**の範囲では十分だが、マルチエージェント化すると素の Python では運用負担が増える。Google の **Agent Development Kit (ADK)** は以下を提供する：

- **Agent / Tool / Workflow の抽象化**: エージェント定義を宣言的に記述
- **マルチエージェント orchestration**: Agent Graph で agent-to-agent 連携を定義
- **Evaluation フレームワーク**: エージェントの出力品質を継続評価
- **Deployment 統合**: Cloud Run / Agent Engine への一発デプロイ

移行タイミングとしては、Phase 4（マルチエージェント）着手時が妥当。単エージェント段階では Function Calling の方が軽量。

#### (C) Vertex AI Agent Builder（GUIベース）の併用

本番運用フェーズに入ると、**非エンジニアがエージェントの振る舞いを調整したい**ニーズが出る：
- プロンプトの文言を営業チームが編集したい
- 新しいツールをローコードで追加したい
- A/Bテストで複数バージョンを比較したい

Vertex AI Agent Builder は GUI でエージェント定義ができるため、**ADK のコードと併用**することで「コア機能はエンジニアが実装、運用調整はビジネス側が実施」という役割分担が実現可能。

#### (D) 観測性（Observability）

本番エージェントは以下を可視化する必要がある：

| 観点 | ツール | 役割 |
|---|---|---|
| **エージェント実行トレース** | Cloud Trace | 各ツール呼出の時系列・レイテンシ・依存関係 |
| **LLM コール詳細** | Vertex AI Logging | プロンプト・応答・トークン数・コスト |
| **エラー集約** | Cloud Error Reporting | 失敗パターンの傾向分析 |
| **品質評価** | Vertex AI Evaluation | 応答の事実正確性・関連性・安全性をスコアリング |
| **カスタムメトリクス** | Cloud Monitoring | 「tool_call 数の異常増加」「iteration 数がmaxに達した率」等 |

デモではツール履歴をレスポンスに含めているが、本番では**全実行を Cloud Trace に投げる**。問題発生時にどのエージェントのどのツール呼出で詰まったかを即座に特定できる。

#### (E) 安全性（Safety / Guardrails）

本番エージェントには以下の安全層が必要：

| リスク | 対策 |
|---|---|
| **プロンプトインジェクション** | 入力サニタイゼーション、system_instruction の保護、出力に対する二次LLMによる検証 |
| **ハルシネーション（事実と異なる出力）** | Grounding（Vertex AI Search 連携）、引用元の必須要件化、信頼度スコア付与 |
| **機密情報漏洩** | 入力 PII マスキング、出力ログのレッドacting、VPC Service Controls |
| **無限ループ / コスト暴走** | max_iterations 強制、トークン上限、Budget アラート |
| **権限昇格** | ツールごとに最小権限、書き戻しツールは別 SA での実行 |
| **有害コンテンツ** | Vertex AI Safety Filters、Output Content Moderation API |

現状のデモは安全層が薄い（max_iterations=15、基本的な安全フィルタのみ）。本番は以下を追加：
- **Input Guardrail**: プロンプトインジェクション検出
- **Output Guardrail**: 出力が業務ルールに反していないか（例「¥5億超の商談は人間の承認必須」）をチェック
- **Audit Log**: 全エージェント実行を BigQuery に蓄積し、後からの監査・トレーニングデータ化に活用

#### (F) 継続的評価（Continuous Evaluation）

エージェントは一度デプロイしたら終わりではなく、**継続的に品質評価する必要がある**：

```
[本番トラフィック]
  ↓
[エージェント実行]
  ↓
[BigQuery に記録: 入力 / 出力 / tool_history / ユーザーフィードバック]
  ↓
[定期的な評価バッチ（Cloud Scheduler）]
  ├─ Vertex AI Evaluation で事実正確性・関連性スコアリング
  ├─ "採用された提案" vs "破棄された提案" の比較
  └─ 不適切な出力パターンの検出
  ↓
[結果を Looker ダッシュボードに可視化]
  ↓
[プロンプト改善・ツール追加・モデル切替の判断材料]
```

### 7.5.4 デモ実装 vs 本番アーキテクチャの対比

| 観点 | デモ（現在） | 本番（目指す姿） |
|---|---|---|
| **エージェント数** | 1（Product Engineering Agent） | 複数（Sales / Field Service / Market Intelligence 等） |
| **オーケストレーション** | なし（単一エージェントが単一タスクを処理） | オーケストレーター Agent が適切なサブエージェントにルーティング |
| **実装フレームワーク** | Vertex AI SDK + 自作ループ | Agent Development Kit (ADK) + Agent Builder 併用 |
| **ツール数** | 10 | 数十〜数百（業務横断で追加） |
| **観測性** | ツール履歴をレスポンス同梱 | Cloud Trace + Vertex AI Logging + Evaluation + Monitoring |
| **安全層** | Gemini 組込 Safety Filter | 入力/出力 Guardrail、PII マスキング、業務ルール違反検知、監査ログ |
| **評価** | 手動確認 | 継続評価バッチ + Looker ダッシュボード |
| **デプロイ** | gcloud CLI 手動 | Cloud Build + Cloud Deploy (CI/CD) + Canary リリース |
| **スケーリング** | min-instances=1 の固定 | 需要予測ベースのオートスケール、GPU プロビジョニング |
| **コスト管理** | 月 ¥800〜¥1,500 | Budget アラート + CUD + トークン節約施策（プロンプトキャッシュ） |

### 7.5.5 段階的な発展パス

| Phase | 内容 | 状態 |
|---|---|---|
| **Phase 1** | 単一 Product Engineering Agent（本デモ） | ✅ 実装済 |
| **Phase 2** | 観測性・安全層の追加（Cloud Trace、Guardrail、監査ログ） | 🔲 |
| **Phase 3** | 第2エージェント追加（Sales Agent 等） | 🔲 |
| **Phase 4** | オーケストレーター導入 + ADK 移行 | 🔲 |
| **Phase 5** | Agent Builder 併用、非エンジニア向け編集UI | 🔲 |
| **Phase 6** | 継続評価・A/Bテスト基盤 | 🔲 |

---

## 8. デモ簡略化と本番構成の対比

### 前提

本デモはデータパイプラインの**考え方**を実証するものであり、すべての処理を本番品質で実装しているわけではない。
以下に「デモで簡略化している箇所」と「本番ではどう構成するか」を整理する。

### 8.1 施策1（市場ニーズ → 製品改善提案）

| 処理 | デモ構成 | 本番構成 | 本番で追加されるGCPサービス |
|---|---|---|---|
| **設計資産の特定** | 仕様書PDF・図面PNGを環境変数で1ファイル固定指定 | 製品マスタとGCSフォルダ構造の紐付け + Vertex AI Embeddingsでセマンティック検索（RAG） | **Vertex AI Embeddings**, **Vector Search** (or AlloyDB), BigQuery |
| **設計資産の格納** | GCSバケットに手動アップロード（2ファイル） | PLMシステムからの定期同期パイプライン。数千〜数万ファイル。バージョン管理付き | **Cloud Storage**（大容量）, **Dataflow** or Cloud Composer（ETL）, **Dataform**（変換） |
| **マルチモーダル処理** | Gemini 1回呼出（PDF 1件 + PNG 1件） | 検索で特定した複数の仕様書・図面を順次またはバッチでGemini処理。結果の品質評価・フィルタリング | **Vertex AI Gemini**（大量呼出）, **Vertex AI Evaluation** |
| **提案結果の蓄積・分析** | DesignSuggestion__cに都度保存のみ | BigQueryにも蓄積し、提案の採用率・効果をダッシュボード化。提案品質の継続改善 | **BigQuery**, **Looker** |
| **ナレッジベース構築** | なし | 過去の設計変更履歴・是正処置をEmbedding化し、提案生成時にコンテキストとして注入 | **Vertex AI Search**, **AlloyDB**（pgvector） |

### 8.2 施策2（IoT → 予兆保全・商談機会）— デモではスライド説明

| 処理 | デモ構成 | 本番構成 | 本番で追加されるGCPサービス |
|---|---|---|---|
| **IoTデータ収集** | HTTPトリガーでダミーJSON送信 | 設備センサーからMQTT/HTTP → Pub/Sub | **Pub/Sub**（大量イベント）, **IoT Core**後継 or パートナー |
| **ストリーム処理** | Cloud Functions内で閾値判定 | Dataflowでリアルタイムストリーム処理（ウィンドウ集計・異常スコア計算） | **Dataflow**（Apache Beam） |
| **時系列データ蓄積** | なし | Bigtable（高頻度書き込み）→ BigQuery（分析用） | **Bigtable**, **BigQuery** |
| **異常検知モデル** | 閾値ベースの簡易ロジック | Vertex AIで予兆保全モデルをトレーニング・サービング | **Vertex AI Training**, **Vertex AI Endpoints** |
| **ダッシュボード** | なし | 設備稼働状況・異常トレンドの可視化 | **Looker**, **BigQuery BI Engine** |
| **ネットワーク** | パブリックインターネット | 工場拠点との専用線接続 | **Cloud Interconnect**, **Cloud VPN** |

### 8.3 共通基盤（両施策横断）

| 処理 | デモ構成 | 本番構成 | 本番で追加されるGCPサービス |
|---|---|---|---|
| **認証・セキュリティ** | JWT Bearer Flow（既存鍵流用） | Workload Identity Federation + Secret Manager + VPC Service Controls | **Secret Manager**, **VPC SC**, **Cloud Armor** |
| **API管理** | Cloud Functions直接公開 | Apigeeまたは Cloud Endpoints でAPI管理・レート制限・監査ログ | **Apigee** or **Cloud Endpoints** |
| **CI/CD** | 手動 gcloud deploy | Cloud Build + Artifact Registry + Cloud Deploy | **Cloud Build**, **Cloud Deploy**, **Artifact Registry** |
| **監視・運用** | Cloud Logging のみ | Cloud Monitoring + Error Reporting + SLO設定 + アラート | **Cloud Monitoring**, **Cloud Trace**, **Error Reporting** |
| **コスト管理** | 無料枠内 | 予算アラート + ラベルベースのコスト配分 + FinOps | **Billing API**, **BigQuery billing export** |

### 8.4 本番構成で期待されるGCPの月額利用規模感（概算）

| カテゴリ | 主要サービス | 概算月額（中規模製造業想定） |
|---|---|---|
| AI/ML | Vertex AI (Gemini, Embeddings, Training, Endpoints) | ¥500K〜¥2M |
| データ基盤 | BigQuery, Bigtable, Cloud Storage | ¥200K〜¥500K |
| ストリーム処理 | Dataflow, Pub/Sub | ¥100K〜¥300K |
| API/セキュリティ | Apigee, Cloud Armor, VPC SC | ¥100K〜¥300K |
| 監視/運用 | Cloud Monitoring, Logging, Trace | ¥50K〜¥100K |
| ネットワーク | Cloud Interconnect | ¥200K〜¥500K |
| **合計** | | **¥1.2M〜¥3.7M/月** |

> **注意**: 上記はデモの文脈で「この構成を本番展開するとGCPのどのサービスがどう使われるか」を示すための概算であり、正確な見積もりではない。実際の費用は利用量・リージョン・契約条件に依存する。

### 8.5 デモから本番への拡張パス

```
Phase 1 (PoC): デモ構成そのまま
  → Cloud Functions + Gemini + GCS
  → 月額: ほぼ無料枠〜数千円
  → 目的: ビジネス価値の検証

Phase 2 (パイロット):
  → RAG構成追加（Vertex AI Embeddings + Vector Search）
  → 仕様書群の自動インジェスト（Cloud Composer or Dataflow）
  → BigQueryへの提案結果蓄積
  → 月額: ¥100K〜¥300K
  → 目的: 複数製品ラインへ展開

Phase 3 (本番展開):
  → IoTパイプライン構築（Pub/Sub + Dataflow + Bigtable）
  → 予兆保全モデル（Vertex AI Training + Endpoints）
  → Apigee API管理 + VPC Service Controls
  → Cloud Interconnect（工場専用線）
  → 月額: ¥1M〜¥4M
  → 目的: 全社展開・継続的改善
```

### 8.6 本番構成のコストドライバー分析

#### 施策1（設計改善提案）単体の場合

| コスト要因 | 性質 | 概算月額 | 備考 |
|---|---|---|---|
| Gemini API呼出 | 従量制 | ¥50〜200/回 | PDF+画像のマルチモーダル入力はトークン量が大きい |
| Vector Search（RAG化後） | **常時稼働** | ¥30K〜60K/月 | 最小構成でもインデックスノードが常時起動 |
| Embeddings生成 | 初期＋差分 | 初期¥10K〜、月¥数千 | PDF追加時のみ |
| Cloud Storage | 従量制 | ¥数百〜数千/月 | 仕様書群のサイズ次第だが安い |

→ 施策1単体では月¥50K〜¥100K程度。最大コストは**Vector Search の常時稼働費用**。

#### 施策2（IoT予兆保全）を加えた場合

| コスト要因 | 性質 | 概算月額 | 備考 |
|---|---|---|---|
| **Bigtable** | **常時稼働** | **¥150K〜300K/月** | 最小3ノード構成。**最大のコストドライバー** |
| Dataflow | 常時稼働 | ¥50K〜100K/月 | ストリーミングワーカー3〜5台が24/7稼働 |
| Pub/Sub | 従量制 | ¥数千/月 | メッセージ量比例、安い |
| Vertex AI Training | 不定期 | ¥50K〜/回 | モデル再学習時のみ |
| Vertex AI Endpoints | 常時稼働 | ¥30K〜60K/月 | 推論エンドポイント |
| Cloud Interconnect | 固定費 | ¥30K〜200K/月 | 接続タイプによる |

→ IoTパイプラインの常時稼働インフラ（特にBigtable）が全体コストの支配的要因。

#### Bigtableが最大コストとなる理由

IoTセンサーデータは「高頻度書き込み × 長期保存 × 低レイテンシ読み取り」の3要件を同時に満たす必要がある。Bigtableはこの要件に最適だが、最小3ノード構成でも月¥150K程度が発生する。BigQueryでは書き込みレイテンシが要件を満たせない。

#### コスト最適化の選択肢

| 手法 | 効果 | トレードオフ |
|---|---|---|
| ホット/コールド階層化 | Bigtable（直近1ヶ月）+ BigQuery（それ以前）で¥50K〜100K削減可 | ETLパイプラインの運用が増える |
| Dataflow バッチ化 | ストリーミング→定期バッチに切替で¥30K〜50K削減 | リアルタイム性が数分〜数十分に劣化 |
| BigQuery ストリーミングインサートで代替 | Bigtable不要で¥150K〜300K削減 | 書き込みレイテンシ数秒、高頻度クエリに不向き |
| Vertex AI Endpoints オートスケーリング | 推論エンドポイントをゼロスケール可能にして¥20K〜40K削減 | コールドスタートで初回推論が遅延 |

> 上記はすべて中規模製造業（設備数千台、センサーデータ数万件/日）を想定した概算。実際の費用は利用量・リージョン・契約条件（CUD等）に依存する。

#### デモ環境のコスト（参考）

| シナリオ | 月額コスト |
|---|---|
| デモ開発・準備期間（数百回呼出） | ¥800〜1,500/月 |
| 散発利用（min-instances=0） | ¥0〜数百円/月 |
| 本番展開（1日100回利用、min=1） | ¥3,000〜5,000/月 |

主要コスト要因：
- Cloud Functions min-instances=1（コールドスタート対策）: 月¥800
- Vertex AI Gemini 2.5 Flash: 1呼出あたり¥0.5〜1.0
- Cloud Storage / Pub/Sub / Logging: 無料枠内

### 8.7 設計資産（仕様書・図面）の発生源とGCPへの同期

#### 発生源システム

B2B製造業において仕様書・図面は以下のシステムから発生する。ほぼ確実にオンプレミスが絡む。

| 発生源 | 生成されるファイル | 典型的な配置 | 代表製品 |
|---|---|---|---|
| **3D CAD** | 図面（DWG/DXF/PDF）、3Dモデル（STEP/IGES） | オンプレ（GPU依存） | SolidWorks, CATIA, Creo, NX |
| **PLM** | 仕様書、設計変更履歴、BOM、承認済み図面PDF | オンプレ（一部クラウド移行中） | Siemens Teamcenter, PTC Windchill, Dassault 3DEXPERIENCE |
| **PDM** | CADファイルのバージョン管理 | オンプレ（CADと密結合） | PLM付属のPDMモジュール |
| **ERP** | 製品マスタ、原価情報、製造BOM | オンプレ or クラウド | SAP S/4HANA, Oracle EBS |
| **文書管理** | 試験報告書、認証書、顧客仕様書 | オンプレ or クラウド | SharePoint, Box, OpenText |
| **ファイルサーバ** | 旧版図面PDF、メンテナンスマニュアル | オンプレ（NAS/SAN） | 部門別フォルダ構造 |

> **デモでの簡略化**: 本デモではCloud Storageに手動アップロードした2ファイル（仕様書PDF・図面PNG）を固定指定している。本番では上記システムからの同期パイプラインが必要。

#### オンプレ → GCP 同期における課題

1. **機密性**: 製品図面は企業の最重要知的財産。クラウドへの配置にはセキュリティ審査・データガバナンス対応が必要
2. **ファイル形式の多様性**: CADネイティブ形式（.sldprt, .catpart 等）はGeminiが直接処理できない。PDF/PNG変換の中間処理が必要
3. **バージョン管理**: PLM上の「Rev.A → Rev.B → Rev.C」の変遷を追跡し、常に最新版をGCP側で参照可能にする必要がある
4. **データ量**: 大型設備メーカーでは数万〜数十万ファイル。全件同期か必要時取得かの設計判断が必要
5. **ネットワーク**: オンプレ → GCP の帯域確保。初期同期で数TB、差分同期で日次数GB

#### 同期アーキテクチャの選択肢

##### パターンA: バッチ同期（最も一般的）

```
[PLM / ファイルサーバ（オンプレ）]
  │ 日次/週次バッチ（PLM API or ファイル監視）
  ▼
[オンプレ同期エージェント]
  │ gsutil rsync / Transfer Service for On Premises
  │ Cloud VPN or Cloud Interconnect 経由
  ▼
[Cloud Storage]
  ├─ products/{product_id}/specs/*.pdf
  ├─ products/{product_id}/drawings/*.png
  └─ products/{product_id}/metadata.json
      ↓ GCS イベント通知 → Pub/Sub
      ↓
[Cloud Functions: インジェストパイプライン]
  ├─ PDF → テキスト抽出（Document AI）
  ├─ CADネイティブ → PNG変換（カスタムコンテナ or パートナーAPI）
  ├─ Embedding生成（Vertex AI Embeddings）
  └─ メタデータ → BigQuery
```

- **利点**: GCP上に最新データが常時存在。検索・Gemini呼出が高速
- **課題**: 同期パイプラインの構築・運用コスト。機密データのクラウド常時配置に対するセキュリティ承認

##### パターンB: オンデマンド取得

```
[Vertex AI Gemini 呼出時]
  │ 対象ファイルをリアルタイムに取得
  ▼
[Cloud Run プロキシ]
  │ PLM REST API or WebDAV 経由
  │ Cloud VPN でオンプレ接続
  ▼
[PLM / ファイルサーバ（オンプレ）]
```

- **利点**: クラウドに機密データを常時配置しない。同期パイプラインの運用不要
- **課題**: レイテンシ増加（数秒〜十数秒追加）。オンプレ側の可用性に依存

##### パターンC: ハイブリッド（推奨）

```
メタデータ + Embedding → バッチ同期（パターンA）
実ファイル本体 → オンデマンド取得 + GCSキャッシュ（パターンB）
```

- **利点**: 検索はGCP上で高速実行。実ファイルは必要時に取得し、頻繁にアクセスされるファイルはGCSにキャッシュ
- **利点**: 機密データの常時クラウド配置を最小化しつつパフォーマンスを確保
- **課題**: 両パターンのインフラが必要

#### 同期に伴う追加GCPサービスとコスト

| 同期方式 | 追加GCPサービス | 追加月額概算 |
|---|---|---|
| パターンA（バッチ） | Transfer Service, Document AI, Cloud Composer | ¥50K〜150K |
| パターンB（オンデマンド） | Cloud VPN, Cloud Run プロキシ | ¥30K〜80K |
| パターンC（ハイブリッド） | 上記両方 + GCSキャッシュポリシー | ¥60K〜150K |
| 共通: ネットワーク | Cloud Interconnect or Cloud VPN | ¥30K〜200K |

> パターンCのハイブリッド方式は、セキュリティ要件と性能要件のバランスが取りやすく、段階的な導入（最初はパターンBで始め、利用頻度の高い資産からパターンAに移行）が可能なため、多くのケースで推奨される。

### 8.8 セキュリティ・データガバナンス

製品図面・仕様書は企業の最重要知的財産であり、クラウドへの配置には厳格なセキュリティ対応が必要となる。

#### 転送・保管時の暗号化

| レイヤー | 対応 | GCPサービス |
|---|---|---|
| 転送中の暗号化 | TLS 1.3（GCPサービス間は自動適用） | デフォルト |
| 保管時の暗号化 | Google管理鍵（デフォルト）or 顧客管理鍵（CMEK） | Cloud KMS |
| 鍵の所在管理 | 顧客がGCP外で鍵を保持する場合 | Cloud External Key Manager（EKM） |

CMEKを使用することで「暗号鍵を自社で管理し、鍵を無効化すればGCP上のデータが即座に読取不能になる」という統制が可能。

#### データの境界制御

| 対策 | 内容 | GCPサービス |
|---|---|---|
| プロジェクト境界 | GCSやVertex AIへのアクセスを特定プロジェクト・VPCに限定 | VPC Service Controls |
| リージョン限定 | 設計資産を日本リージョン（asia-northeast1）に限定し、データが国外に出ないことを保証 | リソースロケーション制約（Organization Policy） |
| IAM最小権限 | Cloud Functions のSAには storage.objectViewer + aiplatform.user のみ付与 | Cloud IAM |
| 監査ログ | 誰がいつどのファイルにアクセスしたかを記録 | Cloud Audit Logs + BigQuery |

#### Vertex AI Gemini へのデータ送信に関する懸念

「Gemini API にPDF・図面を送信した場合、Googleがその内容をモデル学習に使用しないか」は顧客にとって重要な関心事項。

- **Vertex AI API（GCP経由）** の場合: Googleの[Data Governance commitments](https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance)により、**顧客データはモデルのトレーニングに使用されない**ことが契約上保証されている
- これは消費者向けGemini（gemini.google.com）とは異なる。Vertex AI APIは企業向けデータガバナンスが適用される
- 追加の保証が必要な場合、Assured Workloads を利用してコンプライアンス要件（ISO 27001, SOC 2 等）に準拠した環境を構成可能

#### 本デモにおけるセキュリティの簡略化

| 項目 | デモ構成 | 本番で必要な構成 |
|---|---|---|
| 暗号化 | Google管理鍵（デフォルト） | CMEK（Cloud KMS） |
| ネットワーク | パブリックインターネット | Cloud Interconnect + VPC SC |
| Cloud Functions | allow-unauthenticated（公開） | IAM認証必須 + API Gateway |
| SF→GCP認証 | Remote Site Setting + 直接HTTP | Apigee or Cloud Endpoints + mTLS |
| 監査ログ | Cloud Logging のみ | Cloud Audit Logs + SIEM連携 |

### 8.9 AI生成提案の品質管理

Vertex AI Gemini が生成する製品改善提案は、あくまで「AIによる示唆」であり、そのまま設計変更に適用すべきものではない。

#### ハルシネーション（事実と異なる出力）のリスク

| リスク | 具体例 | 影響度 |
|---|---|---|
| 仕様書の誤読 | 存在しないセクション番号を引用する | 中（検証で発見可能） |
| 図面の誤認識 | コンポーネントの位置関係を取り違える | 中〜高 |
| 技術的に不正確な提案 | 物理的に実現不可能な改善案を提示する | 高 |
| 過剰な確信度 | 不確実な提案を断定的に記述する | 中 |

#### 本アーキテクチャにおける品質担保の設計

現在のアーキテクチャでは、以下の3層で品質リスクを緩和している。

**第1層: プロンプト設計による出力制御**
- 構造化JSON出力を強制（自由記述を排除）
- 仕様書のセクション番号・図面名の明示的引用を義務付け → 根拠のない提案を抑制
- temperature=0.2 の低温設定 → 創造的だが不正確な出力を抑制

**第2層: 参照資料の可視化による検証支援**
- LWC上に仕様書PDF・図面PNGをインラインプレビュー → 「Geminiが引用した箇所」を人間がその場で確認可能
- 「P.4 §3.2」と書いてあれば、その場でPDFの該当ページをスクロールして照合できる

**第3層: Human-in-the-loop の設計**
- AI提案は DesignSuggestion__c レコードとして保存されるが、**自動で設計変更を実行しない**
- 設計チームがレコードを確認・評価した上で、Design_Project__c（設計開発プロジェクト）への採用を判断する
- 「AIは示唆を出すだけ。採用するかどうかは人間が決める」という原則

#### 本番で追加すべき品質管理施策

| 施策 | 内容 | GCPサービス |
|---|---|---|
| 出力評価の自動化 | 提案が仕様書の内容と整合しているかを別のLLM呼出で検証（Self-consistency check） | Vertex AI Gemini（評価用呼出） |
| 信頼度スコア付与 | 提案の根拠の強さ（引用箇所の明確さ、複数資料での裏付け）をスコア化 | Vertex AI Evaluation |
| フィードバックループ | 設計チームが「採用/不採用/修正」を記録 → 提案品質の改善指標としてBigQueryに蓄積 | BigQuery + Looker |
| Grounding（根拠づけ） | Vertex AI Search と連携し、提案内容が社内ナレッジベースに根拠を持つかを検証 | Vertex AI Search + Grounding API |

#### PoCで検証すべき項目（図面複雑度）

デモでは図面を Pillow 自動生成の模式図（ブレード+アクチュエータ配置 / BMS 3階層構成）に簡略化している。本番の実CAD図面に差し替えた際には、以下のリスクが顕在化しうるため、**PoC Phase 1 の必須検証項目**として扱う。

| リスク | 内容 | 検証観点 |
|---|---|---|
| 図面内テキストと仕様書の不整合 | 実図面に書かれた部品名・寸法・Fig番号と仕様書§番号の対応がずれ、Geminiが矛盾する引用を生成する | 同一製品の実図面+仕様書での提案生成を N=20〜50 件実行し、引用整合率を測定 |
| 提案の焦点ずれ | 複雑図面から Gemini が寸法・部品形状の詳細提案を引き出し、施策起点（ビジネス課題）から逸脱する | 施策の Why/What がどの程度提案に反映されているかを人手レビューで評価 |
| マルチモーダル処理のレイテンシ増 | 解像度・描き込み量の増加で Gemini 処理時間が伸び、タイムアウトや UX 劣化を招く | p95 レイテンシ測定。閾値超過時は図面のプリプロセス（領域抽出・分割）を検討 |
| 図面内ラベルの OCR 揺れ | 手書き風フォント・注記のかすれ等で Gemini が部品名を誤認識する | 読み取り精度を目視確認。必要に応じて Document AI との2段階処理を検討 |

**デモでの立ち位置**: 模式図でもパイプラインとして成立することを示す。PoC Phase 1 で実図面に差し替え、上記4観点を定量的に評価した上で本番移行の判断を行う。
