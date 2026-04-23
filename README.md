# BPS Corporation - Salesforce Demo Environment

> **Disclaimer**: 本リポジトリは個人が学習・検証目的で構築したSalesforceおよび周辺技術のデモ環境です。
> **Salesforce, Inc.** および日本法人・関連会社とは一切関係がなく、**Salesforce社の公式見解・公式サンプル・製品ロードマップ・推奨実装を示すものではありません**。
> 本リポジトリの内容から同社の将来の機能・方針を推測することはできません。詳細は末尾の [免責事項](#免責事項-disclaimer) を参照してください。

BPS Corporation（架空の再生可能エネルギー機器メーカー）のSalesforceデモ環境です。
製造業における調達・品質・設計・営業の業務プロセスをカスタム実装で再現しています。

## 環境概要

| 項目 | 値 |
|---|---|
| Org | Developer Edition |
| API Version | 66.0 |
| 通貨 | マルチカレンシー（JPY主、USD併用） |
| 権限セット | `BOM_Full_Access` に全カスタムオブジェクトのアクセスを集約 |

### 規模

- **LWC**: 58個
- **Apexクラス**: 75個
- **Prompt Template**: 26個
- **カスタムオブジェクト**: 32個
- **Flow**: 4個
- **Experience Cloud サイト**: 2個（サプライヤーポータル）
- **Cloud Functions (GCP)**: 1個（Vertex AI Function Calling Agent）

## 業務機能一覧

### 1. BOM（部品表）管理
Product2 → BOM_Header → BOM_Line → BOM_SubComponent → BOM_Part の4階層で製品構成を管理。代替BOM対応、製造拠点管理付き。

### 2. サプライチェーン可視化
自社工場4拠点＋サプライヤー拠点11拠点を地図上に表示。災害シミュレーション（南海トラフ/首都直下/東北地震）、キャパシティ管理、代替拠点オフロード提案機能。

### 3. 品質管理（8Dプロセス）
Case → Corrective_Action（8Dフェーズ管理）→ Supplier_Investigation のフロー。AI要約、水平展開分析、ナレッジ自動生成を搭載。

### 4. 調達管理（RFQ）
RFQ → RFQ_Quote の見積依頼〜回答〜比較評価フロー。複数サプライヤーの横並び比較UI付き。

### 5. サプライヤー品質評価
監査（Supplier_Audit）と認証（Supplier_Certification）の管理。品質・納期・コスト・対応力の多軸スコアカード。

### 6. 設計開発管理
Design_Project → Design_Phase のフェーズ管理（ガントチャート）。M-BOM/E-BOM並列比較、BOM階層からの関連ナレッジ検索。

### 7. Manufacturing Cloud 2.0（営業需要管理）
Design Win採用活動 → Revenue_Forecast → Sales_Agreement → 月別Schedule の一気通貫フロー。需要乖離What-ifシミュレーション＋サプライチェーン影響分析。

### 8. ニーズパイプライン（市場インテリジェンス）
面談記録からAIが顧客ニーズを構造化抽出 → ニーズカード → 多軸分析ダッシュボード → 製品施策連携。5タブのニーズ分析ダッシュボード、AIインラインインサイト、鮮度管理。製品施策側ではGCP Vertex AIによる技術裏付け生成まで接続。詳細は [needs-pipeline-setup-guide.md](docs/reference/needs-pipeline-setup-guide.md)

### 9. 商談サマリカード＋類似度分析
商談のコンテキスト（deal_type, customer_segment, sales_motion等）をLLMが構造化抽出しOpportunity_Summary__cに保存。Tier 1（構造化フィールド完全一致）+ Tier 2（Data Cloud Search Index + Retrieverによるベクトル検索）のハイブリッド方式で類似商談を検索。Agentforce Topic経由で分析レポートを生成。LWCパネル（`opportunitySimilarityPanel`）で商談ページに類似商談バッジ表示。

### 10. BOM標準化×LLM名寄せ
BOM_Part__cとSupplier_Part__cのLLMマッチング。Prompt Templateで部品名・スペックの類似判定を行い、サプライヤー部品カタログとの紐付けを自動化。バッチ処理対応。

### 11. Agentforce（従業員エージェント）

**`Agentforce_Employee_Agent`** — InternalCopilot型の従業員エージェント

| トピック | アクション | 機能 |
|---|---|---|
| 取引先分析 | AccountInsightFullAnalysis | 取引先の商談・ケース・活動等を総合分析し、アクション示唆を生成 |
| 取引先サマリ | AccountSummaryTopic | 取引先の概要サマリーを生成 |
| 水平展開分析 | HorizontalDeploymentAnalysis | 是正処置から類似リスクを検索し、影響レポートを生成 |
| ナレッジ作成 | KnowledgeCreationAction | 是正処置の調査結果からKnowledge記事ドラフトを自動生成 |
| BOM分析 | BOMAnalysisGetProductBOM | 製品のBOM構成を分析 |
| サプライヤー影響分析 | BOMAnalysisGetSupplierImpact | サプライヤーに関連するBOM・製品への影響を分析 |
| 商談類似分析 | OpportunitySimilaritySearch | 商談サマリカードから類似商談を検索し分析レポート生成 |

アーキテクチャ: Agent LLM = トピック選択＋アクション推論（ルーティングのみ）、Apex内で `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate()` を呼び出す1アクション統合パターン。

### 12. イベントアンケートRAGパイプライン
S3上のイベントアンケートCSV → Data Cloud（DLO→DMO→ID解決→Data Graph）→ RAGで取引先別傾向分析。CampaignレコードページにLWC（`campaignSurveyAnalysis`）配置。

### 13. 顧客報告メール
Screen Flow `Case_Customer_Report` — CaseレコードページのQuick Actionから起動。Prompt Template `CaseCustomerReport` でAIが顧客向け報告メール文面を生成→レビュー→送信。

### 14. ニーズ相関ネットワーク分析
`needsCorrelationNetwork` LWC — ニーズカード間の相関を bi-gram Jaccard類似度で計算し、k-NNでエッジを削減、業界別クラスタ配置で可視化。市場シグナルの集約性を直感的に把握。詳細は [needs-correlation-network-design.md](docs/design/needs-correlation-network-design.md)

### 15. サプライヤーポータル（Experience Cloud）

Partner Central Enhanced ベースのサプライヤー向けポータル。Wave 1/2 で以下を実装:

| LWC | 機能 |
|---|---|
| `supplierDashboard` | ダッシュボード（発注状況・品質スコア・認証期限） |
| `supplierOrderList` | 受注一覧・出荷ステータス管理 |
| `supplierQualityCard` | 品質スコアカード |
| `supplierCertStatus` | 認証ステータス・期限管理 |
| `supplierInvestigationForm` | 品質調査回答フォーム |
| `supplierRfqResponse` | 見積依頼への回答フォーム |

詳細は [supplier-portal-design.md](docs/design/supplier-portal-design.md) / [supplier-portal-wave2.md](docs/design/supplier-portal-wave2.md)

### 16. GCP連携 — Product Engineering Agent

**Vertex AI Gemini 2.5 Flash + Function Calling** で実装した統合エージェント。Salesforce→GCP→Salesforceの双方向パイプラインを実現。

| シナリオ | トリガー | 処理フロー | 書き戻し先 |
|---|---|---|---|
| **1. 製品施策の技術裏付け** | `designSuggestionGcp` LWC（Product_Initiative__cレコードページ） | 施策 + 紐付けニーズ → 仕様書PDF/図面PNGをマルチモーダル解析 → 技術的改善案を生成 | `DesignSuggestion__c` |
| **2. IoT設備アラート** | Cloud Functions内蔵HTMLトリガー（擬似IoT発火） | 設備情報 + 仕様書からイベント解釈 → 重要度・商談機会を算定 | `Equipment_Alert__c` |

**認証**: GCP→SF は JWT Bearer Flow、SF→GCP は Named Credential + OAuth 2.0 Client Credentials（Google ID Token）

詳細は [gcp_demo_design_concept.md](docs/concepts/gcp_demo_design_concept.md) / [gcp-demo-build-log.md](docs/in-progress/gcp-demo-build-log.md)

### 17. その他ユーティリティ

| LWC | 説明 |
|---|---|
| `accountDashboard` | Account概要ダッシュボード |
| `activityEffortTracker` | 汎用工数トラッカー（WhatIdベースでどのレコードにも配置可能） |
| `opportunityRoadmap` | 商談ロードマップ |
| `batchLauncher` | バッチ処理ランチャー（Apex Batchを即時起動・ステータス監視） |
| `universalTableEditor` | 汎用テーブルエディタ |
| `launcherPanel` | ランチャーパネル |
| `salesforceMogura` | Salesforceもぐらたたきゲーム |
| `salesforceQuizBattle` | Salesforce知識クイズ（AI生成問題） |
| `simpleCalculator` | 電卓 |

## 製品ラインナップ

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

## ディレクトリ構成

```
.
├── force-app/          # Salesforceメタデータ（LWC, Apex, Objects, Flows等）
├── gcp/                # GCP側実装
│   ├── generate-design-suggestion/  # Cloud Functions (Gen2, Python 3.12)
│   └── assets/         # Imagen 3.0生成の製品画像
├── docs/               # 設計書・実装知見
│   ├── reference/      # 環境リファレンス・実装知見
│   ├── design/         # 設計書（実装済み）
│   ├── in-progress/    # 仕掛かり中の設計・作業ログ
│   ├── concepts/       # 構想・論点整理
│   └── archive/lh360/  # LH360（Local Headless 360）のアーカイブ
├── archive/lh360/      # LH360コード一式のアーカイブ
├── data/               # デモデータ（CSV等）
├── manifest/           # package.xml
├── config/             # Scratch org設定
├── CLAUDE.md           # Claude Code プロジェクト指示
└── sfdx-project.json   # SFDXプロジェクト設定
```

### archive/lh360/ について

**Local Headless 360** — ローカルLLM（Gemma 4）+ Salesforce公式MCPでSAE業務を支援するエージェントの実験プロジェクト。Plan-Executor分離、セマンティックレイヤー、β カタログ等の設計を経て、ローカルLLMの推論能力・速度の限界により終了。後継は [h360-view](https://github.com/satoshi-nagahara/h360-view)（Claude Code + MCP + React UI）。顛末は [lh360-retrospective.md](docs/archive/lh360/lh360-retrospective.md)。

## セットアップ

```bash
# orgへの認証（既にJWT認証済みの場合は不要）
sf org login web --alias bps-demo

# メタデータのデプロイ
sf project deploy start --target-org bps-demo

# 権限セットの割り当て
sf org assign permset --name BOM_Full_Access --target-org bps-demo
```

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [demo-environment-guide.md](docs/reference/demo-environment-guide.md) | データモデル・画面構成・デモデータの詳細ガイド |
| [agentforce-architecture-guide.md](docs/reference/agentforce-architecture-guide.md) | Agentforceアーキテクチャ（Agent共存・Topic設計・レコードコンテキスト取得） |
| [data-cloud-lessons-learned.md](docs/reference/data-cloud-lessons-learned.md) | Data Cloud実装知見（DLOカテゴリ制約、ID解決、Data Graph、Search Index等） |
| [known-issues.md](docs/reference/known-issues.md) | 既知問題・技術制約 |
| [picklist-values.md](docs/reference/picklist-values.md) | 選択リスト日本語値リファレンス |
| [google-oauth-setup.md](docs/reference/google-oauth-setup.md) | Google OAuth設定手順（Gmail/Gcal MCP用） |
| [needs-pipeline-setup-guide.md](docs/reference/needs-pipeline-setup-guide.md) | ニーズパイプライン別環境セットアップガイド |
| [supplier-portal-design.md](docs/design/supplier-portal-design.md) | サプライヤーポータル設計書 |
| [needs-correlation-network-design.md](docs/design/needs-correlation-network-design.md) | ニーズ相関ネットワーク設計 |
| [gcp_demo_design_concept.md](docs/concepts/gcp_demo_design_concept.md) | GCP連携デモ設計仕様書 |
| [gcp-demo-build-log.md](docs/in-progress/gcp-demo-build-log.md) | GCP連携デモ構築ログ |

## 免責事項 (Disclaimer)

- 本リポジトリは **個人が制作した非公式のデモ環境** であり、いかなる企業・組織の公式成果物でもありません。
- 特に **Salesforce, Inc.**（米 salesforce.com, inc. および Salesforce Japan 株式会社を含む）とは一切関係がなく、同社の公式見解・サポート対象・製品ロードマップ・将来の機能提供を示すものではありません。本リポジトリに含まれる実装、アーキテクチャ、Agentforce / Data Cloud / Prompt Template 等の利用方法は、すべて個人の解釈と試行に基づく非公式のサンプルです。
- 登場する **BPS Corporation** は架空の企業です。製品名、取引先名、サプライヤー名、人物名、金額、数量、所在地等のデータはすべてデモ用に創作・生成したものであり、実在の個人・団体・取引とは一切関係ありません。
- 本コードは **現状有姿 (AS IS) で提供** され、明示的・黙示的を問わずいかなる保証も行いません。商品性、特定目的適合性、非侵害性、正確性、最新性、セキュリティについての保証を含みません。
- **本番環境での利用は想定していません**。デプロイ、データ利用、外部サービス（GCP / Vertex AI 等）連携による課金・情報漏えい・業務影響等、本リポジトリの利用に起因する一切の損害について作者は責任を負いません。
- LLM・生成AIを用いた機能は、出力の正確性・一貫性を保証しません。業務判断・顧客対応等に利用する場合は、利用者の責任において結果を検証してください。

## 商標 (Trademarks)

- Salesforce, Agentforce, Einstein, Data Cloud, Lightning Web Components, Apex, Experience Cloud, Manufacturing Cloud は salesforce.com, inc. の登録商標または商標です。
- Google Cloud, Vertex AI, Gemini, Imagen, Cloud Functions は Google LLC の登録商標または商標です。
- その他、本リポジトリに記載の製品名・サービス名は、各社の登録商標または商標です。
- 本リポジトリは上記各社から後援・承認・提携を受けているものではありません。

## ライセンス (License)

本リポジトリのソースコードおよびメタデータは **MIT License** の下で公開しています。詳細は [LICENSE](LICENSE) を参照してください。
ただし、生成された製品画像（`gcp/assets/` 配下等、Imagen 3.0 等により生成）の再配布・利用条件は、生成元サービスの利用規約に従います。
