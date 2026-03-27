# BPS Corporation デモ環境ガイド

## 概要

BPS Corporationは再生可能エネルギー機器メーカーという設定の架空企業です。ソーラーパネル、風力タービン、蓄電システム等のハードウェア製品と、エネルギー管理プラットフォーム等のソフトウェア/サービスを扱います。

この環境では、**製造業における調達・品質・設計・営業の業務プロセス**をSalesforceのカスタム実装で再現しています。LWC 36個、Apex 48クラス、Prompt Template 13個、カスタムオブジェクト 25個で構成されています。

---

## 1. BOM（部品表）管理

**「製品は何でできているか」を4階層で管理**

### データモデル

```
Product2（製品マスタ）
  └→ BOM_Header__c（BOMヘッダー） Lookup→Product2 ※代替BOM対応（1製品に複数BOM可）
      ├→ Assembly_Site__c → Manufacturing_Site__c（製造拠点）
      └→ BOM_Line__c（構成品） MD→BOM_Header
          ├ Component_Type__c: アセンブリ/部品/素材/ファントム
          └→ BOM_SubComponent__c（サブ構成品） MD→BOM_Line
              ├ Material_Type__c: 金属/樹脂/電子部品/ゴム/その他
              ├ Process_Type__c: 切削/溶接/組立/外注/購買
              └→ BOM_Part__c（調達部品） MD→BOM_SubComponent
                  ├ Supplier__c → Account（サプライヤー）
                  ├ Manufacturing_Site__c → Manufacturing_Site__c（拠点）
                  └ Make_or_Buy__c: 内製/購買/外注
```

### 画面

- **`bomTreeViewer`** — BOM_Header__cレコードページ。製品のBOMツリーをインデント表示。製造拠点列あり、複数BOM切替対応
- **`dualBOMViewer`** — Design_Projectレコードページ。M-BOM（製造BOM）とE-BOM（設計BOM）の並列比較＋リスク検出

### デモデータ
- 10商品 x 13 BOMヘッダー（うち3商品は代替BOMあり）

---

## 2. サプライチェーン可視化

**「どのサプライヤーがどこで何を作っているか」を地図とグラフで可視化**

### データモデル

```
Manufacturing_Site__c（製造拠点）
  ├ Account__c → Account（サプライヤー or 自社）
  ├ Is_Own_Site__c: Boolean（自社拠点フラグ）
  ├ Location__c: Geolocation（緯度/経度）
  └ BOM_Part__c.Manufacturing_Site__c から参照される

Supplier_Capacity__c（供給キャパシティ）
  ├ Manufacturing_Site__c → Manufacturing_Site__c（MD: 生産拠点）
  ├ Part_Number__c: Text（部品番号）
  ├ Monthly_Capacity__c: Number（月産上限数量）
  ├ Effective_From__c / Effective_To__c: Date（有効期間）
  └ Notes__c: LongTextArea（備考）
```

### 画面

- **`allSitesMap`** — ホーム/AppPage用。自社工場4拠点＋サプライヤー拠点11拠点を地図上にプロット。**災害シミュレーション**機能（南海トラフ/首都直下/東北地震）で被災影響を可視化。**キャパシティ管理**（部品テーブルに月産能力列）、災害時の**代替拠点オフロード提案**機能付き
- **`supplierImpactMap`** — Accountレコードページ。サプライヤーの依存度グラフ（絶対値スケール、3段階リスク色分け、閾値マーカー線）。**キャパシティ逼迫警告**（稼働率80%超過の部品アラート）
- **`supplierDemandOutlook`** — サプライヤーAccountレコードページ。BOM逆引き：このサプライヤーの部品を使っている製品・顧客・商談を一覧表示。確定需要タブ（販売契約ベース）＋パイプラインタブ（DW商談ベース）。**キャパシティアラート**（80%超過品目の警告バナー）
- **`manufacturingSiteMap`** — サプライヤーAccountレコードページ。このサプライヤーの拠点を地図上にプロット。拠点選択で部品テーブル（月産能力列付き）を表示

### デモデータ
- 自社工場4拠点: 浜松(静岡)・名古屋(愛知)・仙台(宮城)・京都(京都)
- サプライヤー拠点11拠点
- Supplier_Capacity__c 約100件（拠点×部品の月産上限。逼迫部品/余裕部品/代替拠点キャパの3パターン）

---

## 3. 品質管理（8Dプロセス）

**「不具合が発生したら、8Dプロセスに沿って是正処置を進める」**

### データモデル

```
Case（顧客クレーム/不具合報告）
  └→ Corrective_Action__c（是正処置） Lookup→Case ※1:N
      ├ Product__c → Product2
      ├ BOM_Part__c → BOM_Part__c（原因部品）
      ├ Supplier__c → Account（原因サプライヤー）
      ├ Team_Leader__c → User
      ├ Parent_CA__c → Corrective_Action__c（自己参照: 水平展開・派生CA用）
      ├ Current_Phase__c: D1〜D8
      ├ Severity__c / Category__c / Impact_Scope__c
      └→ Supplier_Investigation__c（サプライヤー調査） MD→Corrective_Action
          └ Status__c: 依頼中→調査中→回答済→対策実施中→完了（PathAssistant付き）
```

### 画面

- **`correctiveActionProgress`** — Caseレコードページ。紐づく是正処置の8Dフェーズ進捗をビジュアル表示
- **`caSummaryAction`** — Corrective_Actionレコードページ。Quick Actionで**AI要約**を生成（現状のフェーズ進捗・サプライヤー調査状況をLLMが要約）
- **`supplierInvestigationList`** — サプライヤーAccountレコードページ。調査一覧
- **`qualityKpiPanel`** — ホームページ。品質KPI全社サマリー（オープンCA数/期限超過/重大度別/8Dフェーズ分布/カテゴリ内訳）

### Agentforce連携

- **水平展開分析**（`HorizontalDeploymentAction` + Prompt Template）— 1件のCAから類似リスクを持つ他の製品・サプライヤーを検索し、影響レポートを生成
- **ナレッジ作成**（`KnowledgeCreationAction` + Prompt Template）— CAのD2〜D7情報を収集→類似ナレッジをSOSL検索→LLMが統合判断→Knowledge__kavドラフトを自動生成

---

## 4. 調達管理（RFQ）

**「見積依頼→見積回答→比較評価」の調達フロー**

### データモデル

```
RFQ__c（見積依頼）
  ├ BOM_Part__c → BOM_Part__c（対象部品）
  ├ Product__c → Product2
  ├ Status__c / Due_Date__c / Required_Quantity__c
  └→ RFQ_Quote__c（見積回答） MD→RFQ
      ├ Supplier__c → Account
      ├ Unit_Price__c / Lead_Time_Days__c / MOQ__c
      └ Is_Selected__c: Boolean（採用フラグ）
```

### 画面

- **`rfqComparison`** — RFQレコードページ。複数サプライヤーの見積回答を横並び比較
- **`supplierRfqHistory`** — サプライヤーAccountレコードページ。このサプライヤーへの過去RFQ・見積一覧
- **`procurementStatusBoard`** — ホームページ。調達ステータス全社サマリー（オープンRFQ/評価中/期限間近/決定済+カテゴリバッジ+最新見積回答）

### デモデータ
- RFQ 8件、見積回答25件

---

## 5. サプライヤー品質評価

**「サプライヤーの監査・認証・スコアカードを管理」**

### データモデル

```
Account（サプライヤー）
  ├→ Supplier_Audit__c（監査） Lookup→Account
  │   ├ Audit_Type__c: 初回監査/定期監査/特別監査/フォローアップ監査
  │   └ Result__c: 合格/条件付合格/不合格/保留
  └→ Supplier_Certification__c（認証） Lookup→Account
      └ Certification_Type__c: ISO9001/14001/IATF16949/45001/RoHS/REACH/UL
```

### 画面

- **`supplierQualityPanel`** — サプライヤーAccountレコードページ。タブ切替（監査履歴/認証情報）＋サマリー統計バー
- **`supplierScorecard`** — サプライヤーAccountレコードページ。品質・納期・コスト・対応力の多軸評価

### デモデータ
- 監査16件（6社）、認証21件（6社）

---

## 6. 設計開発管理

**「設計プロジェクトのフェーズ管理とナレッジ活用」**

### データモデル

```
Design_Project__c（設計開発プロジェクト）
  ├ Product__c → Product2
  ├ BOM_Header__c → BOM_Header__c（M-BOM）
  ├ EBOM_Header__c → BOM_Header__c（E-BOM）
  └→ Design_Phase__c（設計フェーズ） MD→Design_Project
      ├ Start_Date__c / End_Date__c / Status__c
      └ Phase_Order__c（ガントチャート表示順）

Knowledge__kav（標準Knowledgeオブジェクト）
  ├ RecordType: Design_Knowledge
  ├ Lesson__c / Design_Guideline__c / Procurement_Guideline__c
  ├ Part_Category__c / Search_Keywords__c
  └ Source_CA__c / Source_CAs__c → Corrective_Action（元ネタCA）
```

### 画面

- **`designPhaseGantt`** — Design_Projectレコードページ。フェーズをガントチャートで可視化
- **`dualBOMViewer`** — 同上。M-BOM/E-BOM比較＋リスク検出
- **`designKnowledgePanel`** — 同上。BOM階層からサプライヤー・部品・材料を抽出し、関連するKnowledge記事を関連度スコアリングで表示

---

## 7. Manufacturing Cloud 2.0（営業需要管理）

**「Design Win採用活動→受注予測→販売契約→月別計画/実績→需要変動のサプライチェーン影響」を一気通貫で管理**

### 商談の2トラック

| トラック | RecordType | 用途 |
|---|---|---|
| Design Win | Design_Win | 新製品採用の営業プロセス（引合い→提案→試作→品質認定→最終交渉）。金額はRevenue_Forecastで管理 |
| 通常商談 | SimpleOpportunity / Channel | 標準的な受注フロー |

### データモデル

```
Opportunity（Design Win商談: RecordType=Design_Win）
  ├ StageName: DW_Inquiry→DW_Proposal→DW_Prototype→DW_Qualification→DW_FinalNegotiation
  └→ Revenue_Forecast__c（受注予測） MD→Opportunity, Lookup→Product2
      ├ Fiscal_Year__c / Fiscal_Quarter__c（例: FY2027, Q1）
      ├ Forecast_Quantity__c / Unit_Price__c / Forecast_Amount__c（数式）
      ├ Probability__c / Weighted_Amount__c（数式）
      └ Status__c: 予測中 / 契約移行済

      ── 採用獲得後、designWinConversion LWCで変換 ──

Sales_Agreement__c（販売契約） Lookup→Account, Source_Opportunity__c→Opportunity
  ├ Status__c: 有効 / 更新交渉中 / 終了（PathAssistant付き）
  ├ Contract_Start__c / Contract_End__c
  └→ Sales_Agreement_Product__c（契約製品） MD→Sales_Agreement, Lookup→Product2
      ├ Unit_Price__c
      └→ Sales_Agreement_Schedule__c（月別スケジュール） MD→Sales_Agreement_Product
          ├ Schedule_Month__c（Date）
          ├ Plan_Quantity__c / Plan_Amount__c
          └ Actual_Quantity__c / Actual_Amount__c
```

### 画面

| LWC | 配置先 | 機能 |
|---|---|---|
| `revenueForecastEditor` | Design Win商談ページ | 品目x四半期の数量・単価グリッド編集。全Active製品から選択可、価格表からデフォルト単価取得 |
| `designWinConversion` | Design Win商談ページ | Design Win商談→販売契約への変換（SA＋製品＋空スケジュール自動生成、Revenue_Forecastステータス更新） |
| `salesAgreementChart` | Sales_Agreementページ | 月別計画vs実績のバーチャート |
| `salesAgreementScheduleGrid` | Sales_Agreementページ | 月別スケジュールの編集グリッド |
| `accountForecastPanel` | Accountページ | 取引先別統合フォーキャスト。3タブ（確定収益/DWパイプライン/通常商談）＋年度フィルタ |
| `demandImpactAnalysis` | Sales_Agreementページ | 需要乖離分析＋**What-ifシミュレーション**（需要変動%→BOM展開→サプライヤー影響＋**キャパシティ突合**（稼働率バー、代替拠点提案）＋AI洞察） |
| `supplierDemandOutlook` | サプライヤーAccountページ | 供給側から見た需要（BOM逆引き→確定需要/パイプライン）+ キャパアラート |
| `salesDemandDashboard` | ホームページ | 全社営業需要ダッシュボード。サマリー4指標＋年度別レベニュー棒グラフ＋ステージ別＋製品別需要 |

### パス
- **DesignWinPath** — Design Win商談のステージパス
- **SalesAgreementPath** — 販売契約のステータスパス（有効/更新交渉中/終了）

### デモデータ
- **丸菱商事**: Design Win商談「東南アジア メガソーラー発電プロジェクト」（提案段階25%）、ソーラーパネル＋チャージコントローラー、3年分Revenue Forecast
- **ノヴァテックエレクトロニクス**: Design Win商談「Project PHOENIX 次世代電源ユニット採用」（品質認定75%）、パワーインバーター＋小容量リチウムイオン電池、3年分Revenue Forecast
- **ノヴァテック ATLAS現行モデル**: Sales Agreement（更新交渉中）＋月別Schedule 12ヶ月（半導体不足→年末商戦急増→モデル末期下振れのリアルなパターン）
- 通常商談: 複数社にJPY/USD混在の商談あり（convertCurrencyでJPY統一表示）
- Supplier_Capacity__c: パワーインバーター用部品のキャパ逼迫データ（P-GD-001 ゲートドライバIC、P-MCU-001 MCU等は+20%需要増で超過する設定）

---

## 8. ニーズカード（市場インテリジェンス）

**「営業活動の面談記録から顧客ニーズを構造化抽出し、製品投資判断の材料にする」**

### データモデル

```
Meeting_Record__c（面談記録）
  ├ Account__c → Account
  ├ Opportunity__c → Opportunity
  ├ Summary__c / Transcript__c（131072文字）
  ├ Meeting_Date__c
  └ Needs_Extracted__c: Boolean

Needs_Card__c（ニーズカード）
  ├ Need_Type__c（種別）
  ├ Product__c → Product2
  ├ Title__c / Description__c / Customer_Voice__c
  ├ Business_Impact__c / Priority__c / Status__c
  ├ Source_Meeting__c → Meeting_Record__c
  ├ Merged_From__c → Needs_Card__c（自己参照: merge元）
  ├ Account_Record_Type__c / Account_Type__c / Account_Industry__c（スナップショット）
  └ Business_Unit__c（Opportunity由来）

Needs_Card_Source__c（ソース面談） MD→Needs_Card, Lookup→Meeting_Record
  └ 複数面談→1カードのmergeに対応。鮮度計算の基盤
```

### 画面

- **`needsAnalysisDashboard`** — ホームページ/AppPage。5タブの多軸分析ダッシュボード（製品Family/製品x種別/製品x業種/業種x種別/顧客Top10）。セグメント切替＋時間フィルタ＋指標切替（件数/金額）。バー/セルクリックで**AIがそのセグメントの定性分析をインライン表示**
- **鮮度機能**: Fresh(3M以内)/Aging(3-6M)/Stale(6M超)の3区分でカード鮮度をスタックバー表示

### AI連携
- **ニーズ抽出**: `NeedsCardExtractionAction` — 面談記録からニーズカードを自動生成（重複判定付き）
- **アンケートニーズ抽出**: `EventSurveyNeedsAction` — Data Cloudのイベントアンケートから取引先別にニーズカード自動生成
- **分析インサイト**: `NeedsAnalysisInsight` Prompt Template — セグメント別の定性分析

### バッチ処理
- **`NeedsCardBatch`** — バッチランチャーの「面談＋アンケート → ニーズカード生成」ボタンで起動。未抽出の面談記録を一括処理し、完了後に`EventSurveyNeedsBatch`をチェーン起動してアンケートからのニーズ生成も実行

### デモデータ
- 面談14件、ニーズカード（バッチ実行で動的生成）
- 顧客5社（丸菱商事/ノヴァテック/東亜電子/関東広域エネルギー公社/東日本FG）

---

## 9. Agentforce（従業員エージェント）

**`Agentforce_Employee_Agent`** — InternalCopilot型の従業員エージェント

### トピック

| トピック | アクション | 機能 |
|---|---|---|
| 取引先分析 | AccountInsightFullAnalysis | 取引先の商談・ケース・活動等を総合分析し、アクション示唆を生成 |
| 水平展開分析 | HorizontalDeploymentAnalysis | 是正処置から類似リスクを検索し、影響レポートを生成 |
| ナレッジ作成 | KnowledgeCreationAction | 是正処置の調査結果からKnowledge記事ドラフトを自動生成 |
| BOM分析 | BOMAnalysisGetProductBOM | 製品のBOM構成を分析 |
| サプライヤー影響分析 | BOMAnalysisGetSupplierImpact | サプライヤーに関連するBOM・製品への影響を分析 |

### アーキテクチャ
- Agent LLM = トピック選択＋アクション推論（ルーティングのみ）
- Prompt Template = 実際のテキスト生成（要約・分析・示唆）
- Apex内で `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate()` を呼び出す1アクション統合パターン

---

## 10. 顧客報告メール

- **Screen Flow** `Case_Customer_Report` — CaseレコードページのQuick Actionから起動
- Prompt Template `CaseCustomerReport` でAIが顧客向け報告メール文面を生成→レビュー→送信

---

## 11. その他ユーティリティ

| LWC | 説明 |
|---|---|
| `accountDashboard` | Account概要ダッシュボード |
| `activityEffortTracker` | 汎用工数トラッカー（WhatIdベースでどのレコードにも配置可能） |
| `simpleCalculator` | 電卓 |
| `salesforceQuizBattle` | Salesforce知識クイズ（AI生成問題、温度0.7） |
| `universalTableEditor` | 汎用テーブルエディタ |
| `launcherPanel` | ランチャーパネル |
| `batchLauncher` | バッチ処理ランチャー（ホームページ配置。Apex Batchを即時起動・ステータス監視。3バッチ: 面談＋アンケート→ニーズカード生成 / BOM→サプライヤー名寄せ / 商談→サマリカード生成） |
| `opportunityRoadmap` | 商談ロードマップ |

---

## ページ別LWC配置ガイド

### ホームページ

| LWC | 内容 |
|---|---|
| `salesDemandDashboard` | 営業需要ダッシュボード |
| `qualityKpiPanel` | 品質KPIパネル |
| `procurementStatusBoard` | 調達ステータスボード |
| `allSitesMap` | サプライチェーンマップ＋災害シミュレーション |
| `batchLauncher` | バッチ処理ランチャー |

### サプライヤーAccountページ

| LWC | 内容 |
|---|---|
| `supplierDemandOutlook` | BOM逆引きの需要見通し |
| `supplierImpactMap` | 依存度グラフ |
| `supplierQualityPanel` | 監査・認証情報 |
| `supplierInvestigationList` | サプライヤー調査一覧 |
| `supplierRfqHistory` | RFQ履歴 |
| `supplierScorecard` | スコアカード |
| `manufacturingSiteMap` | サプライヤー拠点マップ（月産能力列付き） |
| `activityEffortTracker` | 工数トラッカー |

### Design Win商談ページ

| LWC | 内容 |
|---|---|
| `revenueForecastEditor` | 四半期別受注予測グリッド |
| `designWinConversion` | 販売契約への変換ボタン |

### Sales_Agreement__cページ

| LWC | 内容 |
|---|---|
| `salesAgreementChart` | 月別計画vs実績バーチャート |
| `salesAgreementScheduleGrid` | スケジュール編集グリッド |
| `demandImpactAnalysis` | 需要乖離＋What-ifシミュレーション |

### 顧客Accountページ

| LWC | 内容 |
|---|---|
| `accountForecastPanel` | 統合フォーキャスト（SA/DW/通常） |
| `accountDashboard` | 概要ダッシュボード |

### Design_Projectページ

| LWC | 内容 |
|---|---|
| `designPhaseGantt` | ガントチャート |
| `dualBOMViewer` | M-BOM/E-BOM比較 |
| `designKnowledgePanel` | 関連ナレッジパネル |

### Caseページ

| LWC | 内容 |
|---|---|
| `correctiveActionProgress` | 8D進捗 |

### Corrective_Action__cページ

| LWC | 内容 |
|---|---|
| `caSummaryAction` | AI現状サマリー（Quick Action） |

### RFQ__cページ

| LWC | 内容 |
|---|---|
| `rfqComparison` | 見積比較 |

### Campaignページ

| LWC | 内容 |
|---|---|
| `campaignSurveyAnalysis` | イベントアンケート反響分析（AI分析実行ボタン、結果表示、再分析。Data Cloud Retriever経由） |

### BOM_Header__cページ

| LWC | 内容 |
|---|---|
| `bomTreeViewer` | BOMツリー表示 |

---

## 製品マスタ（Product2）

ハードウェア10製品＋サービス5製品。全製品にBOMが紐づき、JPY価格表エントリあり。

| コード | 製品名 | Family |
|---|---|---|
| S-100 | ソーラーパネル | モジュール・部品 |
| D-200 | ソーラーチャージコントローラー | 機器・装置 |
| B-1000 | 高容量リチウムイオン電池 | モジュール・部品 |
| C-45678 | 小容量リチウムイオン電池 | モジュール・部品 |
| H-36378 | パワーインバーター | 機器・装置 |
| A-100 | 小型風力タービン | 設備・プラント |
| A-1000 | 大型風力タービン | 設備・プラント |
| E-1000 | エネルギーメーター | 機器・装置 |
| E-2000 | EnerCharge Pro 蓄電システム | 設備・プラント |
| V-1000 | ソーラーEV充電ステーション | 設備・プラント |
| SW-100 | エネルギー管理プラットフォーム | ソフトウェア |
| CS-100 | 設備保全クラウドサービス | クラウドサービス |
| CN-100 | 電力需給最適化コンサルティング | コンサルティング |
| SI-100 | エネルギーシステム導入支援 | SI |
| ES-100 | 設備診断エンジニアリング | エンジニアリングサービス |

---

## サプライヤー（6社）

東亜電子 / テクノコネクト / 日本マテリアルズ / 富士精密機械 / グリーンエナジーセル / サンライズディスプレイ

各社に取引先責任者(計19名)、電話/Website、活動データ、監査・認証データ、拠点情報あり。

---

## 技術情報

- **Org**: Developer Edition (Trailhead Playground)
- **API Version**: 66.0
- **通貨**: マルチカーパンシー（JPY主、USD併用）。ダッシュボード系LWCは `convertCurrency()` でJPY統一表示
- **権限セット**: `BOM_Full_Access` に全カスタムオブジェクト・Apexクラスのアクセスを集約
- **Agentforce**: InternalCopilot (AgentforceEmployeeAgent) 型。UIでのみ作成可能（CLIでは作成不可）
- **Prompt Template**: デプロイ後にPrompt Builder UIで手動Activateが必要
