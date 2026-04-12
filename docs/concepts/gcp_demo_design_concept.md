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
