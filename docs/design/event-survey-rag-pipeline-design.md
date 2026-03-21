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
5. ✅ **データストリーム作り直し（DLO分割）** — 完了（2026-03-20）
   - **経緯**: 当初EventSurveyを「エンゲージメント」カテゴリ1つのDLOで作成したが、エンゲージメントカテゴリではIndividual/Contact Point EmailにマッピングできずID解決に参加できない制約が判明（詳細: `docs/reference/data-cloud-lessons-learned.md`）
   - **対応**: 既存のEventSurveyデータストリームを削除し、DLOを2つに分割して再作成
     - **プロファイルDLO**（プロファイルカテゴリ）: `attendee_email` + `attendee_name` → Individual DMO + Contact Point Email DMO にマッピング → ID解決の対象になる
     - **エンゲージメントDLO**（エンゲージメントカテゴリ）: 回答内容（pain_points, comments, interest_area, product_interest等）→ カスタムDMO `EventSurvey` にマッピング
   - **完了した作業**:
     1. ✅ 既存の EventSurvey データストリーム・DLO・DMO・Data Graph・Search Index を全削除
     2. ✅ `Account.Email_Domain__c` フィールド作成・デプロイ（ドメインマッチ用）
     3. ✅ `BOM_Full_Access` 権限セットに `Account.Email_Domain__c` 権限追加・デプロイ
     4. ✅ レコードトリガーフロー `Account_Extract_Email_Domain` 作成・デプロイ・有効化
     5. ✅ 既存Account 16件のドメイン一括設定（Apex実行）
     6. ✅ プロファイルDLOデータストリーム `*.csv Event Survey S3` 新規作成（プロファイルカテゴリ、PK: survey_id）
        - Individual: Individual Id(PK) ← survey_id, Last Name ← attendee_name, Current Employer Name ← company_name
        - Contact Point Email: Contact Point Email Id(PK) ← survey_id, Email Address ← attendee_email, Email Domain ← email_domain, Party ← survey_id
     7. ✅ エンゲージメントDLOデータストリーム `*.csv Event Survey Engagement S3` 新規作成（エンゲージメントカテゴリ、PK: survey_id）
        - カスタムDMO `EventSurvey` に全13フィールドをマッピング
     8. ✅ ID解決ルールセット「Email Match」再実行 → 468ソース → 455統合（統合率3%、13件統合）
   - **注意点（作業中に判明）**:
     - DLO削除はSearch Index → Data Graph → DMO → DLOの順で依存関係を解消する必要がある
     - Data GraphはUIに削除ボタンがなく、API（`DELETE /ssot/data-graphs/<name>`）で削除可能
     - プロファイルDLOのContact Point EmailにはPartyフィールドのマッピングが必須（Individual紐付け用）。これがないとID解決でマッチしない
     - DLOのプライマリキーは作成後に変更不可。`event_id`（イベント単位）ではなく`survey_id`（回答単位）を選択すること
6. ✅ **Data Graph再定義** — 完了（2026-03-20）
   - Data Graph名: `EventSurveyAccountGraph`（API参照名同じ）
   - 構造: Account → Individual → Contact Point Email → EventSurvey
   - レコード件数: 23件（Account数と一致）、スケジュール: Every 1 Hour
   - **注意点**: EventSurvey DMOにContact Point Emailへのリレーション（attendee_email → Email Address、1対1）を先に作成し、**有効トグルをオン**にしないとData Graphに追加できない
7. ✅ **Search Index + Retriever作成** — 完了（2026-03-21）
   - Search Index `EventSurveySearchIndex`: Hybrid、Multilingual E5 Large
     - チャンキング対象: pain_points, comments, interest_area, product_interest
     - 検索条件の関連項目: event_name, attendee_name, company_name, follow_up_requested, event_id
   - Retriever: `EventSurveySearchIndex_1Cx_dKv65a92b35`（Einstein Studio → Retrievers で有効化済み）
     - 返却フィールド: event_name, attendee_name, company_name, follow_up_requested, event_id
     - 返却チャンク数: 20
8. ✅ **Prompt Template作成** — 完了（2026-03-21）
   - `EventSurveyAnalysis`（イベントアンケート分析）: Flex Template、Retrieverグラウンディング付き → 後方互換用（searchQuery指定時）
   - `EventSurveyAccountNeeds`（取引先別アンケートニーズ抽出）: Flex Template、**Retriever不使用** → 取引先単位分析の本命
     - 入力: accountSurveyData（Data Cloud queryv2で取得した取引先のアンケート回答テキスト）
     - Retrieverではなく構造化データを直接渡すことで、取引先単位の正確な分析を実現
   - `EventSurveyFeedback`（イベント反響分析）: Flex Template、Retrieverグラウンディング付き → キャンペーン全体の反響分析用
   - デプロイ後にPrompt Builder UIで手動Activate必須（3つとも）
9. ✅ **Apex作成** — 完了（2026-03-21）
   - `EventSurveyNeedsAction`（InvocableMethod: イベントアンケートニーズ抽出）
     - **キャンペーンID指定モード（本命）**: Data Cloud queryv2でアンケート回答者メール取得 → CRM Contact/Accountとマッチ → 取引先ごとにData Cloud queryv2で回答データ取得 → 取引先ごとにPrompt Template呼び出し → ニーズカード作成
     - **searchQuery指定モード（後方互換）**: Retriever経由のイベント全体検索
     - Apexのcallout/DML制約対策: 全取引先のHTTP callout+LLM呼び出しを先に実行（callout phase）、その後まとめてDML実行（DML phase）
   - `CampaignSurveyAnalysisAction`（InvocableMethod: キャンペーンアンケート分析）
     - キャンペーンIDからイベント反響分析 + ニーズカード自動生成を一括実行
     - 結果をCampaignレコードのカスタムフィールドに保存
   - `EventSurveyNeedsBatch`（Schedulable + Batchable: 自動ニーズカード生成）
     - 未分析のイベント系キャンペーンを自動検出して処理
   - Needs_Card__c に新規フィールド追加:
     - `Source_Survey_Id__c`（External ID、重複防止用upsert。event_name + accountId + title のSHA-256ハッシュ）
     - `Source_Type__c`（ソース種別ピックリスト）
   - Campaign に新規フィールド追加:
     - `Survey_Sentiment__c`（イベント反響）、`Survey_Key_Findings__c`（主要発見事項）
     - `Survey_Improvements__c`（次回改善点）、`Survey_Analysis__c`（分析全文）、`Survey_Analyzed_Date__c`（分析実行日）
   - **信頼度判定ロジック**:
     - 既存担当者（Contact.Emailがアンケートメールと一致する取引先）→ 優先度そのまま、ステータス「新規」
     - 既存顧客・未登録者（Account.Email_Domain__cがアンケートドメインと一致）→ 優先度そのまま、ステータス「確認済」
     - 取引先不在の回答者 → ニーズカード作成しない（キャンペーン反響分析にのみ反映）
   - **設計判断（作業中に判明）**:
     - Retriever（セマンティック検索）は取引先単位のフィルタリングに不向き。チャンキング対象フィールドにないメタデータ（company_name等）での絞り込みができない
     - 取引先別ニーズカード生成は Data Cloud queryv2 で構造的にデータを取得し、Prompt Templateに直接渡す方式が正確
     - Data Cloud queryv2 のHTTPステータスコードは200ではなく**201**（Created）。ステータスチェックに注意
     - Apexでは DML実行後にHTTP calloutができない。calloutを先に全て実行し、DMLをまとめて後から実行する設計が必要
10. ✅ **テスト実行** — 完了（2026-03-21）
    - キャンペーンID指定 → 5取引先を自動特定、17件ニーズカード作成
      - ノヴァテックエレクトロニクス: 5件（既存担当者）
      - 丸菱商事: 4件（既存担当者）
      - 関東広域エネルギー公社: 3件（既存担当者）
      - 東日本フィナンシャルグループ: 3件（既存担当者）
      - 東亜電子工業: 2件（既存担当者）
    - 取引先不在の回答者はニーズカード非生成（設計通り）

## 追加実装（2026-03-21）

### キャンペーン反響分析 LWC
- `campaignSurveyAnalysis` LWC: キャンペーンレコードページに配置
  - 「分析を実行」ボタン → Retriever経由でイベント全体のアンケートを分析
  - 結果表示: 反響（バッジ）、回答傾向、主要発見事項、参加者セグメント、ポジティブ/ネガティブ反応、次回改善点、次回イベント企画提案
  - 「再分析」ボタンで再実行可能
  - `CampaignSurveyAnalysisAction.analyzeCampaignSurveyLwc` を `@AuraEnabled` で呼び出し
- キャンペーンの反響分析は**全回答者（新規含む）**のデータを対象。ニーズカードは**既存取引先の回答者のみ**対象

### スケジュールBatch（ニーズカード自動生成）
- `EventSurveyNeedsBatch`: Schedulable + Batchable + AllowsCallouts
- **差分検知**: Data Cloudデータストリームの最終更新日とCampaign.Survey_Analyzed_Date__cを比較。新CSVが取り込まれた場合のみ処理実行
- スケジュール登録: `EventSurveyNeedsBatch.scheduleDaily()` で毎日朝6時実行（未登録）

### 設計判断
- **LWCの反響分析ではニーズカード生成しない**（Batchに任せる）。理由: 責務の分離、LLM呼び出し回数の最適化
- **Screen Flowは不採用** → キャンペーンオブジェクトのLWC制約（動的フォーム非対応）のため直接LWCで実装
- `@InvocableMethod` と `@AuraEnabled` は同一クラスの同一内部クラスで併用不可 → LWC用は別メソッド `analyzeCampaignSurveyLwc` として分離

## 実装完了（2026-03-21）

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
