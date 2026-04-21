# ニーズパイプライン セットアップガイド

面談記録 → ニーズカード → ニーズ分析 → 製品施策 のデータパイプラインを別環境に構築するためのガイド。

## 目次

1. [全体アーキテクチャ](#1-全体アーキテクチャ)
2. [前提条件](#2-前提条件)
3. [Phase 1: カスタムオブジェクト・フィールド](#3-phase-1-カスタムオブジェクトフィールド)
4. [Phase 2: 権限セット](#4-phase-2-権限セット)
5. [Phase 3: UI（タブ・レイアウト・クイックアクション）](#5-phase-3-uiタブレイアウトクイックアクション)
6. [Phase 4: Prompt Template（Einstein AI）](#6-phase-4-prompt-templateeinstein-ai)
7. [Phase 5: Apex クラス](#7-phase-5-apex-クラス)
8. [Phase 6: Flow](#8-phase-6-flow)
9. [Phase 7: LWC](#9-phase-7-lwc)
10. [Phase 8: FlexiPage配置](#10-phase-8-flexipage配置)
11. [Phase 9: バッチスケジュール](#11-phase-9-バッチスケジュール)
12. [Phase 10: 動作確認](#12-phase-10-動作確認)
13. [オプション拡張](#13-オプション拡張)
14. [トラブルシューティング](#14-トラブルシューティング)

---

## 1. 全体アーキテクチャ

### データフロー

```
┌─────────────────┐     AI抽出        ┌──────────────┐
│ Meeting_Record  │───────────────────▶│  Needs_Card  │
│   (面談記録)     │   Flow/Apex/PT    │ (ニーズカード) │
└─────────────────┘                    └──────┬───────┘
        │                                     │
        │                          ┌──────────┴──────────┐
        │                          │                     │
        ▼                          ▼                     ▼
 Needs_Card_Source__c    Needs_Analysis_Cache__c   Initiative_Need__c
   (ソース紐付け)          (分析キャッシュ)           (施策紐付け)
                                                        │
                                                        ▼
                                                Product_Initiative__c
                                                  (製品施策)
```

### コンポーネント一覧

| レイヤー | コンポーネント | 説明 |
|---------|-------------|------|
| オブジェクト | Meeting_Record__c | 面談記録。取引先・商談に紐づく |
| オブジェクト | Needs_Card__c | AIが抽出した顧客ニーズの構造化データ |
| オブジェクト | Needs_Card_Source__c | 面談記録⇔ニーズカードの中間オブジェクト |
| オブジェクト | Needs_Analysis_Cache__c | AI分析結果のキャッシュ |
| オブジェクト | Product_Initiative__c | ニーズに基づく製品施策 |
| オブジェクト | Initiative_Need__c | 施策⇔ニーズカードの中間オブジェクト（MD） |
| Apex | NeedsCardExtractionAction | 面談記録→ニーズカード抽出（Invocable） |
| Apex | NeedsCardBatch | 未抽出面談を一括処理するバッチ |
| Apex | NeedsAnalysisController | ニーズ分析ダッシュボードのバックエンド |
| Apex | InitiativeNeedsMatcherController | 施策⇔ニーズの紐付け支援 |
| Flow | Needs_Card_Extraction | 面談記録から手動でニーズ抽出を起動 |
| LWC | needsAnalysisDashboard | ニーズ分析ダッシュボード |
| LWC | initiativeNeedsMatcher | 施策⇔ニーズ紐付けUI |
| PT | NeedsCardExtraction | 面談内容→ニーズJSON変換プロンプト |
| PT | NeedsAnalysisInsight | ニーズ集合の分析インサイト生成 |
| PT | InitiativeNeedsRelevance | 施策⇔ニーズ関連度分析 |

---

## 2. 前提条件

### org要件

| 要件 | 必須/推奨 | 備考 |
|-----|----------|------|
| Einstein for Sales（またはEinstein 1 Edition） | **必須** | Prompt Template実行に必要 |
| Einstein Studio / Model Builder | **必須** | LLMモデルの有効化 |
| 標準オブジェクト: Account, Opportunity, Product2 | **必須** | Lookupの参照先 |
| Account.RecordType | 推奨 | セグメント分析で使用 |
| Account.Industry | 推奨 | 業種分析で使用 |
| Product2.Family | 推奨 | 製品ファミリー集計で使用 |

### Einstein AI モデル設定

全Prompt Templateで **Claude 4.5 Sonnet**（`sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet`）を使用する。

**Setup > Einstein > Generative AI** で Claude 4.5 Sonnet が有効化されていることを確認すること。

### 選択リスト値（日本語）

このパイプラインで使用する選択リスト値は全て日本語。事前に把握しておく:

**Needs_Card__c.Need_Type__c:**
- 製品ニーズ / サービスニーズ / クレーム / 改善要望 / 新規案件

**Needs_Card__c.Priority__c:**
- 高 / 中 / 低

**Needs_Card__c.Status__c:**
- 新規 / 確認済 / 対応中 / 完了 / 却下

**Meeting_Record__c.Meeting_Type__c:**
- （orgの選択リスト定義に従う）

**Product_Initiative__c.Status__c:**
- 起案 / 評価中 / 承認 / 実行中 / 完了

**Product_Initiative__c.Priority__c:**
- 高 / 中 / 低

---

## 3. Phase 1: カスタムオブジェクト・フィールド

### デプロイ順序（依存関係に基づく）

依存関係があるため、以下の順序でデプロイする:

```
① Meeting_Record__c         ← Account, Opportunity への Lookup のみ
② Needs_Card__c             ← Account, Opportunity, Product2, Meeting_Record__c への Lookup
③ Needs_Card_Source__c      ← Meeting_Record__c, Needs_Card__c への Lookup
④ Needs_Analysis_Cache__c   ← 他オブジェクトへの参照なし（独立）
⑤ Product_Initiative__c     ← Product2 への Lookup のみ
⑥ Initiative_Need__c        ← Product_Initiative__c (MD), Needs_Card__c (Lookup)
```

### 対象ファイル

```bash
# Phase 1 デプロイコマンド（対象ファイルを指定）
sf project deploy start \
  --source-dir force-app/main/default/objects/Meeting_Record__c \
  --source-dir force-app/main/default/objects/Needs_Card__c \
  --source-dir force-app/main/default/objects/Needs_Card_Source__c \
  --source-dir force-app/main/default/objects/Needs_Analysis_Cache__c \
  --source-dir force-app/main/default/objects/Product_Initiative__c \
  --source-dir force-app/main/default/objects/Initiative_Need__c \
  --target-org YOUR_USERNAME
```

### 各オブジェクトのフィールド詳細

#### Meeting_Record__c（面談記録）- 8フィールド

| API名 | 型 | 説明 | 参照先 |
|-------|---|------|-------|
| Account__c | Lookup | 取引先 | Account |
| Opportunity__c | Lookup | 関連商談 | Opportunity |
| Meeting_Date__c | Date | 面談日 | - |
| Meeting_Type__c | Picklist | 面談種別 | - |
| Participants__c | LongTextArea | 参加者 | - |
| Summary__c | LongTextArea | 面談サマリー | - |
| Transcript__c | LongTextArea | 文字起こし | - |
| Needs_Extracted__c | Checkbox | ニーズ抽出済み | - |

#### Needs_Card__c（ニーズカード）- 21フィールド

| API名 | 型 | 説明 | 参照先 |
|-------|---|------|-------|
| Account__c | Lookup | 取引先 | Account |
| Source_Meeting__c | Lookup | ソース面談記録 | Meeting_Record__c |
| Source_Opportunity__c | Lookup | ソース商談 | Opportunity |
| Product__c | Lookup | 関連製品 | Product2 |
| Merged_From__c | Lookup | 統合元（自己参照） | Needs_Card__c |
| Title__c | Text(255) | ニーズタイトル | - |
| Need_Type__c | Picklist | ニーズ種別 | - |
| Priority__c | Picklist | 優先度 | - |
| Status__c | Picklist | ステータス | - |
| Description__c | LongTextArea | 詳細説明 | - |
| Customer_Voice__c | LongTextArea | 顧客の声（原文引用） | - |
| Business_Impact__c | Currency | ビジネスインパクト金額 | - |
| Impact_Source__c | Text | インパクト金額の根拠 | - |
| Account_Record_Type__c | Text | 取引先レコードタイプ（転記） | - |
| Account_Type__c | Text | 取引先タイプ（転記） | - |
| Account_Industry__c | Text | 取引先業種（転記） | - |
| Business_Unit__c | Text | 事業部（商談から転記） | - |
| Customer_Segment__c | Text | 顧客セグメント | - |
| Source_Type__c | Text | ソース種別 | - |
| Source_Survey_Id__c | Text(ExternalId) | アンケートソースID（upsertキー） | - |
| Related_Cards__c | LongTextArea | 関連カードメモ | - |

#### Needs_Card_Source__c（ソース紐付け）- 2フィールド

| API名 | 型 | 説明 | 参照先 |
|-------|---|------|-------|
| Meeting_Record__c | Lookup | 面談記録 | Meeting_Record__c |
| Needs_Card__c | Lookup | ニーズカード | Needs_Card__c |

#### Needs_Analysis_Cache__c（分析キャッシュ）- 10フィールド

| API名 | 型 | 説明 |
|-------|---|------|
| Filter_Key__c | Text(ExternalId) | フィルタキー（upsertキー） |
| Analysis_Text__c | LongTextArea | 分析結果テキスト |
| Suggestion_Title__c | Text | 施策提案タイトル |
| Suggestion_What__c | LongTextArea | 施策提案 What |
| Suggestion_Why__c | LongTextArea | 施策提案 Why |
| Default_Product_Id__c | Text | デフォルト製品ID |
| Products_Json__c | LongTextArea | 製品オプションJSON |
| Card_Ids_Json__c | LongTextArea | 対象カードIDリストJSON |
| Card_Count__c | Number | 対象カード数 |
| Generated_At__c | DateTime | 生成日時 |

#### Product_Initiative__c（製品施策）- 14フィールド

| API名 | 型 | 説明 | 参照先 |
|-------|---|------|-------|
| Product__c | Lookup | 対象製品 | Product2 |
| Title__c | Text(255) | 施策タイトル | - |
| What_Description__c | LongTextArea | 概要（What） | - |
| Why_Rationale__c | LongTextArea | 根拠（Why） | - |
| Approach__c | LongTextArea | アプローチ | - |
| Status__c | Picklist | ステータス | - |
| Priority__c | Picklist | 優先度 | - |
| Estimated_Cost__c | Currency | 見積コスト | - |
| Estimated_Revenue__c | Currency | 見積収益 | - |
| Target_Customer__c | Text | ターゲット顧客 | - |
| Target_Industry__c | Text | ターゲット業種 | - |
| Target_Release__c | Date | 目標リリース日 | - |
| Target_Start__c | Date | 目標開始日 | - |
| Decision_Note__c | LongTextArea | 判断メモ | - |

#### Initiative_Need__c（施策ニーズ紐付け）- 3フィールド

| API名 | 型 | 説明 | 参照先 |
|-------|---|------|-------|
| Initiative__c | Master-Detail | 施策 | Product_Initiative__c |
| Needs_Card__c | Lookup | ニーズカード | Needs_Card__c |
| Relevance_Note__c | LongTextArea | 関連度メモ | - |

---

## 4. Phase 2: 権限セット

`BOM_Full_Access` 権限セットに以下を追加する（または新規権限セットを作成）:

### オブジェクト権限

| オブジェクト | CRUD | 備考 |
|------------|------|------|
| Meeting_Record__c | 全て | - |
| Needs_Card__c | 全て | - |
| Needs_Card_Source__c | 全て | - |
| Needs_Analysis_Cache__c | 全て | - |
| Product_Initiative__c | 全て | - |
| Initiative_Need__c | 全て | MDなのでRead/Createが最低限 |

### フィールド権限

上記6オブジェクトの全カスタムフィールドに Read/Edit を付与する。

```bash
# 権限セットのデプロイ
sf project deploy start \
  --source-dir force-app/main/default/permissionsets/BOM_Full_Access.permissionset-meta.xml \
  --target-org YOUR_USERNAME
```

### ユーザーへの割り当て

```bash
sf org assign permset --name BOM_Full_Access --target-org YOUR_USERNAME
```

---

## 5. Phase 3: UI（タブ・レイアウト・クイックアクション）

### タブ

```bash
sf project deploy start \
  --source-dir force-app/main/default/tabs/Meeting_Record__c.tab-meta.xml \
  --source-dir force-app/main/default/tabs/Needs_Card__c.tab-meta.xml \
  --source-dir force-app/main/default/tabs/Product_Initiative__c.tab-meta.xml \
  --target-org YOUR_USERNAME
```

### クイックアクション

面談記録の作成・ニーズ抽出を手動起動するためのアクション:

```bash
sf project deploy start \
  --source-dir force-app/main/default/quickActions/Account.New_Meeting_Record.quickAction-meta.xml \
  --source-dir force-app/main/default/quickActions/Opportunity.New_Meeting_Record.quickAction-meta.xml \
  --source-dir force-app/main/default/quickActions/Meeting_Record__c.Extract_Needs.quickAction-meta.xml \
  --target-org YOUR_USERNAME
```

### Path Assistant（製品施策）

```bash
sf project deploy start \
  --source-dir force-app/main/default/pathAssistants/ProductInitiative.pathAssistant-meta.xml \
  --target-org YOUR_USERNAME
```

---

## 6. Phase 4: Prompt Template（Einstein AI）

### テンプレート一覧

| テンプレート | 使用元 | 入力パラメータ | モデル |
|------------|-------|-------------|-------|
| NeedsCardExtraction | NeedsCardExtractionAction.cls | `Input:meetingContext` (String) | Claude 4.5 Sonnet |
| NeedsAnalysisInsight | NeedsAnalysisController.cls | `Input:needsData` (String) | Claude 4.5 Sonnet |
| InitiativeNeedsRelevance | InitiativeNeedsMatcherController.cls | `Input:analysisData` (String) | Claude 4.5 Sonnet |

### デプロイ

```bash
sf project deploy start \
  --source-dir force-app/main/default/genAiPromptTemplates/NeedsCardExtraction \
  --source-dir force-app/main/default/genAiPromptTemplates/NeedsAnalysisInsight \
  --source-dir force-app/main/default/genAiPromptTemplates/InitiativeNeedsRelevance \
  --target-org YOUR_USERNAME
```

### デプロイ後の手動設定

1. **Setup > Einstein > Prompt Builder** を開く
2. 各テンプレートを開き、**Activate（有効化）** する
3. モデルが `sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet`（Claude 4.5 Sonnet）に設定されていることを確認
4. **Setup > Einstein > Generative AI** で Claude 4.5 Sonnet が有効化されていることを確認

> **注意**: Prompt Templateはデプロイしただけでは動作しない。必ずActivateが必要。
> Activateされていないと `Prompt Templateからの応答が空です` エラーが発生する。

---

## 7. Phase 5: Apex クラス

### デプロイ順序（依存関係に基づく）

```
① NeedsCardExtractionAction.cls      ← Prompt Template "NeedsCardExtraction" に依存
② NeedsCardBatch.cls                 ← NeedsCardExtractionAction に依存
③ NeedsAnalysisController.cls        ← Prompt Template "NeedsAnalysisInsight" に依存
④ InitiativeNeedsMatcherController.cls ← Prompt Template "InitiativeNeedsRelevance" に依存
```

### デプロイ

```bash
sf project deploy start \
  --source-dir force-app/main/default/classes/NeedsCardExtractionAction.cls \
  --source-dir force-app/main/default/classes/NeedsCardExtractionAction.cls-meta.xml \
  --source-dir force-app/main/default/classes/NeedsCardBatch.cls \
  --source-dir force-app/main/default/classes/NeedsCardBatch.cls-meta.xml \
  --source-dir force-app/main/default/classes/NeedsAnalysisController.cls \
  --source-dir force-app/main/default/classes/NeedsAnalysisController.cls-meta.xml \
  --source-dir force-app/main/default/classes/InitiativeNeedsMatcherController.cls \
  --source-dir force-app/main/default/classes/InitiativeNeedsMatcherController.cls-meta.xml \
  --target-org YOUR_USERNAME
```

### NeedsCardBatch のチェーン起動について

`NeedsCardBatch.finish()` は `EventSurveyNeedsBatch` をチェーン起動する。
EventSurvey連携は今回スコープ外のため、**finish()メソッドの中身をコメントアウトする**:

```apex
// NeedsCardBatch.cls の finish() メソッドを以下に変更
public void finish(Database.BatchableContext bc) {
    System.debug('NeedsCardBatch 完了。');
    // EventSurvey連携はスコープ外のためチェーン起動を無効化
    // try {
    //     Datetime streamLastUpdate = EventSurveyNeedsBatch.getDataStreamLastUpdate();
    //     ...
    // } catch (Exception e) { ... }
}
```

> コメントアウトしないと、`EventSurveyNeedsBatch` クラスが存在しないためコンパイルエラーになる。

### NeedsCardExtractionAction の環境依存ポイント

このクラスは以下の環境固有ロジックを含む。自環境に合わせて修正すること:

1. **製品名キーワードマップ（L389-413）**: `findProductByPartialMatch` メソッド内のキーワード→製品名マッピングは、この環境の Product2 データに依存している。自環境の製品に合わせて書き換えること。

2. **日本語フィルタ（L155）**: `containsJapanese()` でSDOデモデータの英語製品名を除外している。全製品が日本語名なら不要。

3. **Revenue_Forecast__c 参照（L85-96）**: 商談金額がnullの場合に `Revenue_Forecast__c` オブジェクトから取得するロジックがある。このオブジェクトがない環境ではこのブロックを削除すること。

---

## 8. Phase 6: Flow

```bash
sf project deploy start \
  --source-dir force-app/main/default/flows/Needs_Card_Extraction.flow-meta.xml \
  --target-org YOUR_USERNAME
```

### Flow の動作

1. 面談記録のレコードページからクイックアクション「ニーズ抽出」で起動
2. 確認画面を表示 →「ニーズを抽出する」ボタンで実行
3. `NeedsCardExtractionAction` を呼び出し、Prompt Template経由でAI抽出
4. 結果（作成数/統合数/スキップ数）を表示

### デプロイ後の確認

- Flow が **Active** であること（Setup > Flows で確認）
- クイックアクション `Meeting_Record__c.Extract_Needs` が Flow を呼び出すこと

---

## 9. Phase 7: LWC

### デプロイ

```bash
sf project deploy start \
  --source-dir force-app/main/default/lwc/needsAnalysisDashboard \
  --source-dir force-app/main/default/lwc/initiativeNeedsMatcher \
  --target-org YOUR_USERNAME
```

### 各LWCの機能と依存

| LWC | 機能 | Apexコントローラー | 配置先 |
|----|------|-----------------|-------|
| needsAnalysisDashboard | ニーズの集計・可視化・AI分析・施策起案 | NeedsAnalysisController | App Page / Home Page |
| initiativeNeedsMatcher | 施策レコードにニーズカードを紐付け | InitiativeNeedsMatcherController | Product_Initiative__c Record Page |

### needsAnalysisDashboard のコントローラー確認

LWCの先頭で import しているコントローラーが `NeedsAnalysisController`（V1）であることを確認:

```javascript
// NeedsAnalysisController（V1）を使用
import getAnalysisData from '@salesforce/apex/NeedsAnalysisController.getAnalysisData';
import analyzeSegment from '@salesforce/apex/NeedsAnalysisController.analyzeSegment';
import suggestInitiative from '@salesforce/apex/NeedsAnalysisController.suggestInitiative';
import createInitiativeFromDashboard from '@salesforce/apex/NeedsAnalysisController.createInitiativeFromDashboard';
```

---

## 10. Phase 8: FlexiPage配置

### レコードページ

```bash
sf project deploy start \
  --source-dir force-app/main/default/flexipages/FlexiPage8.flexipage-meta.xml \
  --source-dir force-app/main/default/flexipages/FlexiPage12.flexipage-meta.xml \
  --target-org YOUR_USERNAME
```

| FlexiPage | 用途 |
|-----------|------|
| FlexiPage8 | Meeting_Record__c レコードページ |
| FlexiPage12 | Product_Initiative__c レコードページ |

### 手動設定（デプロイ後）

1. **Setup > Object Manager > Meeting_Record > Lightning Record Pages** で FlexiPage8 をデフォルトに設定
2. **Setup > Object Manager > Product_Initiative > Lightning Record Pages** で FlexiPage12 をデフォルトに設定
3. needsAnalysisDashboard は Lightning App Page を作成して配置（またはHomeページに配置）

---

## 11. Phase 9: バッチスケジュール

未抽出の面談記録を定期的に処理するバッチをスケジュールする:

### 開発者コンソールから実行

```apex
// 毎日午前2時に実行（cronExpression）
System.schedule(
    'NeedsCardBatch Daily',
    '0 0 2 * * ?',
    new NeedsCardBatchScheduler()
);
```

### Scheduler クラスがない場合

```apex
// 匿名Apexで直接スケジュール
System.schedule('NeedsCardBatch Daily', '0 0 2 * * ?', new Schedulable() {
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new NeedsCardBatch(), 1);
    }
});
```

> **バッチサイズは1を推奨**: LLM呼び出しを含むため、1レコードずつ処理してCalloutエラーを回避する。

---

## 12. Phase 10: 動作確認

### Step 1: 面談記録を手動作成

1. 取引先レコードを開く
2. クイックアクション「新規面談記録」で面談記録を作成
3. 以下を入力:
   - 面談日
   - 面談サマリー（顧客ニーズが含まれる内容を記載）
   - 取引先（自動設定）

### Step 2: ニーズカード抽出を実行

1. 作成した面談記録を開く
2. クイックアクション「ニーズ抽出」を実行
3. 結果画面で作成数を確認

### Step 3: 確認ポイント

- [ ] ニーズカードが作成されていること（ニーズカードタブで確認）
- [ ] Title、Need_Type、Priority、Description、Customer_Voice が適切に設定されていること
- [ ] 取引先への紐付け（Account__c）が正しいこと
- [ ] Needs_Card_Source__c レコードが作成されていること
- [ ] 面談記録の Needs_Extracted__c が true になっていること

### Step 4: 分析ダッシュボード確認

1. needsAnalysisDashboard を配置したページを開く
2. ニーズカードの集計が表示されることを確認
3. セグメントをクリックしてAI分析が動作することを確認

### Step 5: 施策起案フロー確認

1. 分析ダッシュボードから「施策を起案」を実行
2. Product_Initiative__c レコードが作成されることを確認
3. Initiative_Need__c でニーズカードが紐付いていることを確認

---

## 13. オプション拡張

以下は本ガイドのスコープ外だが、リポジトリに実装が含まれている拡張機能:

### A. NeedsCardRAG（Data Cloud Retriever）

ニーズカードをベクトル検索できるRAGテンプレート。

**追加で必要なもの:**
- Data Cloud の Search Index（Needs_Card DMO に作成）
- Einstein Studio の Retriever
- Prompt Template: `NeedsCardRAG`

### B. EventSurvey連携（Data Cloud）

イベントアンケートからもニーズカードを自動生成する機能。

**追加で必要なもの:**
- Data Cloud の EventSurvey DMO（Data Model Object）
- `EventSurveyNeedsAction.cls` / `EventSurveyNeedsBatch.cls`
- Prompt Template: `EventSurveyAnalysis`, `EventSurveyAccountNeeds`
- Account に `Email_Domain__c` カスタムフィールド

---

## 14. トラブルシューティング

### よくあるエラー

| エラー | 原因 | 対処 |
|-------|------|------|
| `Prompt Templateからの応答が空です` | Prompt Template が Activate されていない | Setup > Prompt Builder で Activate |
| `テンプレートがActivateされているか確認してください` | 同上、または使用モデルが無効 | Einstein > Generative AI でモデル有効化 |
| `取引先が設定されていません` | 面談記録に Account__c が未設定 | 面談記録の取引先を設定 |
| `面談サマリーまたは文字起こしが空です` | Summary__c / Transcript__c が両方空 | いずれかに内容を入力 |
| `LLMレスポンスからJSONを抽出できませんでした` | AIの出力形式が想定外 | Prompt Template の出力指示を調整 |
| FLS エラー | 権限セットの設定不足 | BOM_Full_Access にフィールド権限を追加 |
| `Revenue_Forecast__c` 参照エラー | 該当オブジェクトが存在しない | NeedsCardExtractionAction L85-96 を削除 |
| `EventSurveyNeedsBatch` 参照エラー | NeedsCardBatch.finish() のチェーン起動が残っている | finish() のチェーン起動をコメントアウト |

### デプロイ時のエラー

| エラー | 対処 |
|-------|------|
| `Entity of type 'CustomObject' is not available` | オブジェクトのデプロイ順序を確認。依存先を先にデプロイ |
| `Field does not exist: Revenue_Forecast__c.xxx` | Revenue_Forecast__c オブジェクトを作成するか、参照コードを削除 |
| `No such column 'Business_Unit__c' on Opportunity` | Opportunity にカスタムフィールド Business_Unit__c を追加するか、該当行を削除 |

---

## 補足: ファイル一覧（コピー用）

このパイプラインに関連する全ファイルの一覧:

```
# オブジェクト（6個）
force-app/main/default/objects/Meeting_Record__c/
force-app/main/default/objects/Needs_Card__c/
force-app/main/default/objects/Needs_Card_Source__c/
force-app/main/default/objects/Needs_Analysis_Cache__c/
force-app/main/default/objects/Product_Initiative__c/
force-app/main/default/objects/Initiative_Need__c/

# Apexクラス（4個）
force-app/main/default/classes/NeedsCardExtractionAction.cls
force-app/main/default/classes/NeedsCardBatch.cls
force-app/main/default/classes/NeedsAnalysisController.cls
force-app/main/default/classes/InitiativeNeedsMatcherController.cls

# LWC（2個）
force-app/main/default/lwc/needsAnalysisDashboard/
force-app/main/default/lwc/initiativeNeedsMatcher/

# Prompt Template（3個）
force-app/main/default/genAiPromptTemplates/NeedsCardExtraction/
force-app/main/default/genAiPromptTemplates/NeedsAnalysisInsight/
force-app/main/default/genAiPromptTemplates/InitiativeNeedsRelevance/

# Flow
force-app/main/default/flows/Needs_Card_Extraction.flow-meta.xml

# タブ
force-app/main/default/tabs/Meeting_Record__c.tab-meta.xml
force-app/main/default/tabs/Needs_Card__c.tab-meta.xml
force-app/main/default/tabs/Product_Initiative__c.tab-meta.xml

# クイックアクション
force-app/main/default/quickActions/Account.New_Meeting_Record.quickAction-meta.xml
force-app/main/default/quickActions/Opportunity.New_Meeting_Record.quickAction-meta.xml
force-app/main/default/quickActions/Meeting_Record__c.Extract_Needs.quickAction-meta.xml

# Path Assistant
force-app/main/default/pathAssistants/ProductInitiative.pathAssistant-meta.xml

# FlexiPage
force-app/main/default/flexipages/FlexiPage8.flexipage-meta.xml
force-app/main/default/flexipages/FlexiPage12.flexipage-meta.xml

# 権限セット
force-app/main/default/permissionsets/BOM_Full_Access.permissionset-meta.xml
```
