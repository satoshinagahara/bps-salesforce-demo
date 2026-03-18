# イベントアンケート → Data Cloud RAG → ニーズカード自動生成パイプライン

作成日: 2026-03-15

## 概要

外部のイベント参加者アンケートデータ（CSV）をData Cloudに取り込み、CRMの取引先・担当者と紐付けた上で、RAGで取引先別のアンケート傾向を分析し、ニーズカード（Needs_Card__c）を自動生成するパイプライン。

## アーキテクチャ

```
[S3 or Ingestion API] イベントアンケートCSV（メールアドレス+回答内容）
  ↓ Cloud Storage Connector or Ingestion API
[Data Cloud DLO] アンケート生データ
  ↓ マッピング
[Data Cloud DMO] EventSurvey（カスタム）
  ↓ ドメインマッチ or メールアドレス一致
[Data Cloud DMO] Individual / Account
  ↓ Data Graph で結合
[EventSurvey] ← [Individual] → [Account]
  ↓
[Prompt Template + Retriever] 取引先別にアンケート傾向を分析 → ニーズJSON出力
  ↓
[Apex or Flow] JSON → Needs_Card__c レコード自動作成
```

## データフロー詳細

### 1. アンケートCSVの構造（想定）

| カラム | 説明 |
|---|---|
| event_id | イベントID |
| event_name | イベント名 |
| attendee_email | 参加者メールアドレス |
| attendee_name | 参加者氏名 |
| company_name | 会社名（自由記入） |
| interest_area | 関心分野（選択式） |
| pain_points | 課題・悩み（自由記入テキスト） |
| product_interest | 興味のある製品・サービス |
| follow_up_requested | フォローアップ希望（Y/N） |
| comments | 自由コメント |
| email_domain | メールアドレスのドメイン部分（前処理で追加） |

### 2. CRM側との名寄せ（ドメインマッチ方式）

#### 既存Contact一致（メールアドレス完全一致）
- アンケートの attendee_email と CRM Contact.Email が一致 → 直接紐付け
- Identity Resolutionの標準Exactマッチで対応

#### 未登録者の取引先特定（ドメインマッチ）
- CSVに `email_domain` 列を前処理で追加（例: tanaka@toyota.co.jp → toyota.co.jp）
- Account側に `Email_Domain__c` カスタム項目を追加、FlowでWebsiteから自動抽出
- Data Cloud上でドメインキーマッチ → 取引先を特定

**前処理でドメイン列を追加する方式を採用**（Calculated Insightより設定がシンプルで確実）

#### マッチ結果による処理分岐
| マッチ結果 | 処理 |
|---|---|
| 既存Contactに一致 | 取引先に紐付けてニーズカード作成 |
| Contact不一致、Accountドメイン一致 | 新規リードとして自動作成 + ニーズカード紐付け |
| どちらも不一致 | 新規リード（取引先未特定）として作成 |

### 3. Data Graph 構成

ルートDMO: Account
- → Individual（ContactPointEmail経由）
- → EventSurvey（ドメインマッチ or Individual経由）

これにより「取引先Xのイベント参加者全員のアンケート回答」を1クエリで取得可能。

### 4. RAG分析（Prompt Template）

#### 入力
- 取引先ID or 取引先名
- イベントID（特定イベントに絞る場合）

#### Retrieverの検索対象
- EventSurveyのDMO（pain_points, comments等のテキストフィールド）

#### LLM出力（JSON形式）
```json
{
  "account_name": "トヨタ自動車",
  "event_name": "製造DXセミナー 2026春",
  "attendee_count": 3,
  "common_interests": ["設備IoT", "予知保全"],
  "key_pain_points": [
    "設備稼働率の可視化ができていない",
    "保全計画が属人化している"
  ],
  "suggested_needs_cards": [
    {
      "title": "設備稼働率リアルタイム可視化",
      "need_type": "製品ニーズ",
      "priority": "高",
      "customer_voice": "「設備の稼働状況がリアルタイムで見えないため...」",
      "description": "イベントアンケートで3名中2名が言及。設備IoTによる稼働率可視化ニーズ。"
    }
  ]
}
```

### 5. ニーズカード自動作成（Apex）

LLM出力のJSONをパースし、Needs_Card__c レコードを作成：
- Title__c ← suggested_needs_cards[].title
- Need_Type__c ← need_type
- Priority__c ← priority
- Customer_Voice__c ← customer_voice
- Description__c ← description
- Account__c ← マッチした取引先ID
- Status__c ← "新規"

## 実装パターン

| パターン | トリガー | 実装 | 向いてる場面 |
|---|---|---|---|
| **A: バッチ処理** | アンケート取込完了後に自動実行 | Apex Batch → Prompt Template(ConnectApi) → DML | イベント後の一括処理 |
| **B: エージェント対話** | ユーザーが「このイベントのニーズを抽出して」と指示 | Agentforce → Apex Action → Prompt Template → DML | 対話しながら内容を確認・修正 |

## 実装ステップ

1. ✅ **デモ用アンケートCSV作成** — 完了（2026-03-16）
   - ファイル: `data/event_survey_decarbonization_2026.csv`
   - 30名分（既存Contact一致10名 / 既存顧客CRM未登録7名 / 完全新規13名）
   - メール未記入2名、会社名表記ゆれ、回答の丁寧さバラつきなどリアルな雑さを再現
   - キャンペーン「BPS脱炭素ソリューション説明会 2026」(701Ie0000008y8lIAA) を作成済み
   - 主要顧客4社（丸菱商事/ノヴァテック/関東広域エネルギー公社/東日本FG）に取引先責任者15名を追加済み
2. ✅ **AWS S3バケット作成** + CSVアップロード — 完了（2026-03-17）
   - バケット: `snagahara-poc-938145531465-ap-southeast-2-an` / フォルダ: `event-surveys/`
   - IAMユーザー: `datacloud-s3-reader`（S3読取専用ポリシー `DataCloud-S3-ReadOnly`）
3. ✅ **Data Cloud S3 Cloud Storage Connector設定** — 完了（2026-03-17）
   - コネクタ: `Event Survey S3`（S3バケット接続確認済み、ワイルドカード `*.csv` 対応済み）
4. ✅ **CRM同期** — 完了（2026-03-17）
   - Salesバンドル（Account/Contact/Lead/Opportunity/User/OpportunityContactRole）をデータストリームとして追加
   - 自動でDMOマッピング + 取り込み完了（Account 23件等）
   - Data Cloudの個人データ構造: Lead/ContactのFirst/Last Name → Individual DMO、Email → Contact Point Email DMO
5. ⚠️ **データストリーム作り直し（DLO分割）** — 次のステップ
   - **経緯**: 当初EventSurveyを「エンゲージメント」カテゴリ1つのDLOで作成したが、エンゲージメントカテゴリではIndividual/Contact Point EmailにマッピングできずID解決に参加できない制約が判明（詳細: `docs/data-cloud-lessons-learned.md`）
   - **対応**: 既存のEventSurveyデータストリームを削除し、DLOを2つに分割して再作成
     - **プロファイルDLO**（プロファイルカテゴリ）: `attendee_email` + `attendee_name` → Individual DMO + Contact Point Email DMO にマッピング → ID解決の対象になる
     - **エンゲージメントDLO**（エンゲージメントカテゴリ）: 回答内容（pain_points, comments, interest_area, product_interest等）→ カスタムDMO `EventSurvey` にマッピング → Contact Point Emailへのリレーションで紐付け
   - **作業手順**:
     1. 既存の EventSurvey データストリーム・DLO・DMO・Data Graph・Search Index を削除
     2. プロファイルDLOデータストリーム新規作成（S3同一コネクタ、プロファイルカテゴリ）
        - `survey_id`, `attendee_email`, `attendee_name` をIndividual + Contact Point Emailにマッピング
     3. エンゲージメントDLOデータストリーム新規作成（S3同一コネクタ、エンゲージメントカテゴリ）
        - 回答内容をカスタムDMO EventSurveyにマッピング
        - Contact Point Emailへのリレーション設定
     4. ID解決ルールセット「Email Match」を再実行 → 統合率が改善されるはず
6. **Data Graph再定義**（Account × Individual × Contact Point Email × EventSurvey）
7. **Search Index + Retriever作成**（EventSurvey DMOに対して作成）
8. **Prompt Template作成**（CLI: アンケート分析 → ニーズカードJSON出力、Retriever + Data Graph併用）
9. **Apex作成**（CLI: JSON → Needs_Card__c レコード作成）
10. **テスト実行**

## 再利用する既存アセット

- Prompt Template: ConnectApi経由のApex呼び出しパターン（BOM_Analysis_Agentで実証済み）
- ニーズカード作成: Apex DML（既存スキルで対応可能）
- Data Cloud Retriever: 2026-03-15に構築したNeedsCard RAGパイプラインと同じ手順
- Search Index: Hybrid + Multilingual E5 Large（日本語対応、実証済み）

## 本番運用設計

### 運用フロー

```
[S3にCSV格納]
  ↓ Cloud Storage Connector（定期同期: 1時間〜24時間で設定）
[Data Cloud] 差分取り込み → DMOに新規レコード追加 → Search Index自動増分更新
  ↓ トリガー
[Apex Batch] 未処理アンケートを検出 → Prompt Template(ConnectApi)で分析 → リード + ニーズカード作成
```

### Batch起動トリガーの選択肢

| 方式 | 仕組み | 向いてるケース |
|---|---|---|
| **スケジュールBatch** | 定期的に「未処理のアンケートDMO」をクエリして処理 | シンプル。1日1回〜数回で十分な場合 |
| **Data Cloud Triggered Flow** | DMOへのレコード追加をトリガーにFlowが起動 | リアルタイム性が必要な場合 |
| **Platform Event** | Data CloudからPlatform Eventを発火→Apex Triggerで処理 | 複雑な後続処理がある場合 |

### 差分管理・重複防止（重要）

同じアンケートから二重にリード・ニーズカードを作らないための設計。

#### 一意キー
- アンケートCSVに一意キーを持たせる: `event_id` + `attendee_email` の組み合わせ
- Data Cloud側のDMOでもこの組み合わせをプライマリキーまたはユニークキーとして扱う

#### 処理済み管理（2方式）

**方式A: インポートログオブジェクト**
```
Survey_Import_Log__c（カスタムオブジェクト）
  - Event_Id__c: テキスト
  - Attendee_Email__c: テキスト（メールアドレス）
  - Source_Key__c: テキスト（event_id + email のハッシュ。External ID + Unique）
  - Processed_Date__c: 日時
  - Created_Lead__c: 参照（Lead）
  - Created_Needs_Cards__c: テキスト（作成したニーズカードIDのカンマ区切り）
  - Status__c: 選択リスト（成功 / エラー / スキップ）
  - Error_Message__c: ロングテキスト
```

Apex Batch処理フロー:
1. Data Cloud DMOから全アンケートレコードを取得
2. Survey_Import_Log__c の Source_Key__c と突合
3. 未処理のレコードのみ処理対象
4. 処理完了後、ログレコードを作成

**方式B: ニーズカード側にソースID**
```
Needs_Card__c に追加:
  - Source_Survey_Id__c: テキスト（External ID + Unique）
    値: event_id + "__" + attendee_email のハッシュ
```

Upsertで重複防止:
- `Source_Survey_Id__c` をExternal IDとしてupsert
- 同じアンケートから再処理しても既存レコードを更新するだけ

**推奨: 方式Aと方式Bの併用**
- 方式A（ログ）: 処理状況の追跡・エラーハンドリング・再処理制御
- 方式B（External ID）: 万が一の二重実行時のセーフティネット

#### リード重複防止
- `attendee_email` でCRM Contact/Lead を事前検索
- 既存Contact → スキップ（既に取引先に紐付いている）
- 既存Lead → スキップまたは更新
- 未登録 → 新規Lead作成

```apex
// 重複チェックの擬似コード
Map<String, Contact> existingContacts = getContactsByEmail(emailSet);
Map<String, Lead> existingLeads = getLeadsByEmail(emailSet);

for (SurveyRecord survey : surveys) {
    if (existingContacts.containsKey(survey.email)) {
        // 既存Contact → 取引先IDを取得してニーズカードのみ作成
        accountId = existingContacts.get(survey.email).AccountId;
    } else if (existingLeads.containsKey(survey.email)) {
        // 既存Lead → スキップまたは情報更新
    } else {
        // 新規Lead作成 + ドメインマッチで取引先候補を提示
        newLeads.add(createLead(survey));
    }
}
```

### エラーハンドリング

| エラー | 対処 |
|---|---|
| Data Cloud同期失敗 | データストリームのステータス監視。失敗時はアラート通知 |
| Prompt Template呼び出し失敗 | Survey_Import_Log__c にエラー記録。リトライ対象としてマーク |
| JSON パースエラー | LLM出力が不正JSON → フォールバック（生テキストをDescription__cに保存） |
| DML エラー（必須項目不足等） | ログに記録、次レコードの処理は継続（partial success） |

### モニタリング

- Survey_Import_Log__c のダッシュボード: 処理件数、成功率、エラー率
- Data Cloudデータストリームの同期状況: 最終更新日時、レコード数推移

## 備考

- Ingestion APIのベースパスは `/api/v1/ingest/`（Connect APIの `/services/data/` とは異なる）
- Search Index構築には15〜20分かかる（レコード数による）
- Retriever作成はSearch Indexが「準備完了」になってから
- Prompt Template はMetadata APIデプロイ後にUI手動Activateが必要
- S3 Cloud Storage Connectorの同期間隔は最短1時間（リアルタイムではない）
- Data Cloud Triggered Flowを使えばDMOレコード追加をリアルタイム検知可能だが、大量データには向かない
