# BPS Corporation - Salesforce Demo Environment

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

- **LWC**: 36個
- **Apexクラス**: 48個
- **Prompt Template**: 13個
- **カスタムオブジェクト**: 25個

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

### 8. ニーズカード（市場インテリジェンス）
面談記録からAIが顧客ニーズを構造化抽出。5タブの多軸分析ダッシュボード、AIインラインインサイト、鮮度管理機能。

### 9. Agentforce（従業員エージェント）
InternalCopilot型エージェント。取引先分析、水平展開分析、ナレッジ作成、BOM分析、サプライヤー影響分析の5トピック。Apex + Prompt Template統合パターン。

### 10. イベントアンケートRAGパイプライン（構築中）
S3上のイベントアンケートCSV → Data Cloud → RAGで取引先別傾向分析 → ニーズカード自動生成。詳細は `docs/in-progress/event-survey-rag-pipeline-design.md` を参照。

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
├── docs/               # 設計書・実装知見
│   ├── reference/      # 環境リファレンス・実装知見
│   ├── design/         # 設計書（実装済み）
│   ├── in-progress/    # 仕掛かり中の設計・作業ログ
│   └── concepts/       # 構想・論点整理
├── data/               # デモデータ（CSV等）
├── manifest/           # package.xml
├── config/             # Scratch org設定
├── CLAUDE.md           # Claude Code プロジェクト指示
└── sfdx-project.json   # SFDXプロジェクト設定
```

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

詳細なデータモデル、画面構成、デモデータの説明は [docs/reference/demo-environment-guide.md](docs/reference/demo-environment-guide.md) を参照してください。
