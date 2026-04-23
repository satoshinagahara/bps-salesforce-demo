# 納入商品LTV × Vertex AI による Projection 高度化 構想

**目的**：Asset単位のLTV（生涯売上）の将来予測部分を、静的な規則ベース計算から Vertex AI の推論に置き換え、精度の高い Projected LTV を出す
**作成日**：2026-04-23
**ステータス**：未着手（LTV第一版は純Salesforce集計で構築予定。本構想はその拡張）

---

## 1. 背景

納入商品ページに配置する LTV LWC（`assetLtvGcp`）は、第一版では以下を Apex で集計する方針：

- **Realized LTV** = `Asset.Price` + 実施済マイルストーンの `Actual_Amount__c` 合計
- **Projected LTV** = Realized + 予定マイルストーンの `Planned_Amount__c` 合計 + `Equipment_Alert__c.Estimated_Opportunity__c` 合計

この Projection は「すでに登録されている将来イベントの単純合計」に留まり、以下の示唆を取りこぼす。

## 2. 何が足りないか

| 観点 | 第一版で不足する情報 |
|------|---------------------|
| 保守更新の継続率 | 保守契約更新予定が登録されていても、実際に更新されるかは不明。過去の顧客行動・設備状態から継続確率を推論したい |
| 追加商談の発生確率 | 類似設備・類似顧客において、残耐用年数内に発生した追加商談の頻度・金額分布から、本設備で今後発生する追加商談の期待値を推定したい |
| 異常検知起点のコンバージョン率 | Equipment_Alert の `Estimated_Opportunity__c` は「理論値」。実際にアラートから商談化した履歴を学習し、確度補正をかけたい |
| 残耐用年数内の大型支出 | 設備の稼働状況 (`Asset_Availability__c`, `TotalUsage__c`, `Average_Time_Between_Failures__c`) からリプレース時期・大型修繕発生確率を予測したい |

## 3. アーキテクチャ案

```
Salesforce (Asset + 関連データ)
    │
    │ Apex → Vertex AI Endpoint (Cloud Function 経由)
    ▼
GCP
    ├─ Vertex AI: LTV Projection Model
    │    入力: Asset特性 + 顧客属性 + マイルストーン履歴 + アラート履歴 + 稼働KPI
    │    出力: 期待追加売上、保守継続確率、リプレース時期分布、信頼区間
    │
    └─ BigQuery: 学習データ（過去納入設備の実績LTV）
         既存のRAG基盤（Product Engineering Agent）と同居可能
```

既存の Product Engineering Agent と同じ `asia-northeast1-ageless-lamp-251200` プロジェクト内に Vertex AI モデル・エンドポイントを追加する想定。

## 4. 出力のイメージ

LWC の表示を以下で拡張：

- **Projected LTV** に信頼区間を併記（例: ¥5.2億 [P25: ¥4.1億 / P75: ¥6.3億]）
- **ドライバー分解**: Projected のうち「保守更新由来 60%」「アップグレード由来 25%」「消耗品・部品 15%」のような内訳（SHAP的な寄与度）
- **リスクシグナル**: 「類似設備の平均より保守継続確率が低い」等の注意喚起

## 5. 必要な学習データ

- 過去に納入〜廃棄までライフサイクルが完結した設備の実績売上データ
- Asset特性（製品種別・価格帯・顧客業界・設置環境）
- マイルストーン履歴（種別・間隔・実績額）
- アラート発生履歴と商談化の有無
- 顧客属性（業種・規模・取引年数）

**現状の制約**：デモ環境にはライフサイクル完結データが無いため、学習用ダミーデータの生成ロジックを別途設計する必要がある。

## 6. 第一版との接続点

第一版の `AssetLtvController` が以下のどちらかを選べる構造にしておけば、将来のVertex AI連携時に移行コストが最小化される：

```apex
// 第一版
Projection p = LtvCalculator.projectStatic(assetId);

// 将来版（環境変数 USE_VERTEX_AI で切替）
Projection p = UseVertexAi ?
    LtvCalculator.projectWithVertexAi(assetId) :
    LtvCalculator.projectStatic(assetId);
```

GCP RAG化時の `USE_RAG` 環境変数方式と同じパターン。

## 7. 優先度

第一版（規則ベース集計）完成後、以下が揃った段階で着手を検討：

- デモ環境で過去設備のLTV実績データが一定量生成できる
- 既存のVertex AI活用（Product Engineering Agent）が安定稼働している
- ユーザーから「Projection の根拠が欲しい」等のフィードバックがある

## 8. 関連ドキュメント

- `docs/in-progress/gcp-rag-migration-design.md` — Product Engineering Agent の RAG化（同じVertex AI基盤を使う前例）
- `docs/concepts/gcp_demo_design_concept.md` — SF×GCP連携デモ全体の設計コンセプト
