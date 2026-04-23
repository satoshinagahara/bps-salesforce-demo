# 納入商品LTV LWC 設計書

**目的**：1台の納入商品（Asset）が廃棄までに会社にもたらす累計売上（LTV）を、納入商品ページで可視化する
**作成日**：2026-04-23
**ステータス**：実装完了（第一版：純Salesforce集計）

---

## 1. LTV の定義

B2B 重工系の "1台の設備が生涯で生む累計売上" として、以下4要素の売上ベース合計。

| # | 要素 | 性質 | データソース |
|---|------|------|-------------|
| ① | 初期納入 | 単発・確定 | `Asset.Price × Asset.Quantity` |
| ② | 保守・サービス実績 | 反復・確定 | `Asset_Milestone__c.Actual_Amount__c`（Status=実施済） |
| ③ | 保守・サービス予定 | 反復・未確定 | `Asset_Milestone__c.Planned_Amount__c`（Status≠実施済） |
| ④ | アラート起点の想定商談 | 不定期・未確定 | `Equipment_Alert__c.Estimated_Opportunity__c`（Status≠解決済） |

**計算式**：
- Realized LTV = ① + ②
- Projected LTV = Realized + ③ + ④
- LTV倍率 = Projected LTV / ①（1台の設備が初期売価の何倍のリターンを生むか）

Opportunity (Account単位) は第一版では意図的に無視。Asset単位のSoTが無く、按分推定を入れると精度が不明確になるため。

## 2. データモデル変更

### 2.1 Asset_Milestone__c（既存オブジェクトに2フィールド追加）

| フィールド | 型 | 用途 |
|----------|-----|------|
| `Planned_Amount__c` | Currency(18,0) | 予定金額（Status=予定の時に使用） |
| `Actual_Amount__c` | Currency(18,0) | 実績金額（Status=実施済の時に使用） |

既存のAPI名と同じフィールドが `Sales_Agreement_Schedule__c` 等にも存在するが、カスタムフィールドはオブジェクトごとにスコープされるため衝突なし。

### 2.2 Asset（標準オブジェクトに3フィールド追加）

| フィールド | 型 | 用途 |
|----------|-----|------|
| `Realized_LTV__c` | Currency(18,0) | 実績LTVのキャッシュ（一覧・レポート用） |
| `Projected_LTV__c` | Currency(18,0) | 予測LTVのキャッシュ |
| `LTV_Multiple__c` | Number(5,2) | LTV倍率のキャッシュ |

LWC表示は毎回 Apex で再計算（DTO返却）するため、Asset側フィールドは一覧ビュー・レポートで使う用途。現状は Apex 匿名ブロック（`/tmp/refresh_asset_ltv.apex`）で手動更新。将来的に Asset_Milestone__c の Trigger で自動更新化の余地あり。

### 2.3 FLS

`BOM_Full_Access` 権限セットに上記5フィールドを追加（本プロジェクトの規約に準拠）。

## 3. Apex Controller

`AssetLtvController.cls` — [force-app/main/default/classes/AssetLtvController.cls](../../force-app/main/default/classes/AssetLtvController.cls)

### 3.1 API

```apex
@AuraEnabled(cacheable=true)
public static LtvView getLtv(Id assetId)
```

### 3.2 DTO構造

- `LtvView` — LWC表示の最上位DTO
  - `realizedLtv`, `projectedLtv`, `ltvMultiple`（数値）
  - `*Formatted`（¥○億/¥○万表示用の文字列）
  - `breakdown: Breakdown` — 4要素の内訳
  - `yearlySeries: List<YearlyPoint>` — 年度別の累積売上（SVGグラフ用）
  - `paybackYears`, `annualAvgService`, `nextMajorEvent` — KPI

### 3.3 計算ロジック要点

- アラート集計は `Status__c != '解決済'` で除外（ピックリスト値: 新規/対応中/解決済）
- yearlySeries は納入年から最終マイルストーン年までの累積カーブ。アラート分は発生年不明のため「今年」に計上（近似）
- paybackYears は「納入価額と同額の追加売上が積み上がる年数」として定義（単発販売ビジネスなので納入時点で売上は計上済 → 倍率2.0到達年数）
- nextMajorEvent は予定マイルストーンの中で最大の Planned_Amount を持つイベント

### 3.4 金額フォーマット

```
>= 1億: ¥N.NN億
>= 1万: ¥N万
その他: ¥N
```

## 4. LWC: assetLtvGcp

[force-app/main/default/lwc/assetLtvGcp/](../../force-app/main/default/lwc/assetLtvGcp/)

### 4.1 レイアウト構成

1. **Hero**: 予測LTV大表示 + LTV倍率バッジ（≥1.3: 緑 / ≥1.1: 黄 / <1.1: 赤）
2. **スタックバー**: 4要素 (初期納入/保守実績/保守予定/アラート見込) の構成を視覚化
3. **年次累積SVGグラフ**: 納入年から最終年までの累積売上カーブ。本日位置は赤破線、未来点はオレンジ
4. **KPI下段**: 年平均サービス売上 + 次の大型支出イベント
5. **脚注**: LTV計算式の説明

### 4.2 LWCテンプレート制約への対応

LWC テンプレートは属性値に三項演算子を書けないため、SVG circle の fill 色などはJS側（`chartData.points[i].fill`）で事前計算。

### 4.3 配置

`Asset_BPS_Demo` FlexiPage に独立タブ「LTV」として追加（納入商品タブの右隣）。

## 5. デモデータ設計

### 5.1 マイルストーン金額の投入方針

納入価額に対して、保守系は全ライフサイクルで 10-15% 程度が現実的な製造業の相場。

**Asset 1: EnerCharge Pro #001（納入価額 ¥1.8億・蓄電システム）**
- 保守実績（既往分）¥12.95M — 年間¥0.8M程度 + 故障対応¥3.5M
- 保守予定 ¥18.80M — 年間点検 + 5年保守契約更新¥15M
- アラート見込 ¥108M — 稼働中アラート1件（重複2件は解決済化）
- **Projected LTV ¥3.20億 / 倍率 ×1.78**

**Asset 2: A-1000 大型風力タービン #003（納入価額 ¥3.5億・風力設備）**
- 保守実績 ¥39.6M — 年間¥1.5-1.8M × 3年 + 部品交換¥12M
- 保守予定 ¥39.8M — 5年保守契約更新¥35M 中心
- アラート見込 ¥0 — アラート無し
- **Projected LTV ¥4.29億 / 倍率 ×1.23**

### 5.2 投入スクリプト

`/tmp/update_milestone_amounts.apex` — Milestone Name をキーに Planned/Actual を一括更新
`/tmp/refresh_asset_ltv.apex` — 全Assetの LTVサマリフィールドを AssetLtvController.getLtv() で再計算して DML

これらは tmp 配置で本番運用には含まれない。新環境構築時は同等のスクリプトを再生成する。

### 5.3 重複 Equipment_Alert の処理

デモ中のリプレイで同一設備に対して同一 Estimated_Opportunity のアラートが3件発生していた（EA-0029/EA-0031/EA-0033、いずれも ¥108M）。Projected LTV が ¥5.36億（倍率2.98x）と過大になったため、古い2件（EA-0029/EA-0031）を Status='解決済' に変更し、最新の EA-0033 のみを有効にした。

## 6. 既存機能への影響

ゼロ。以下を事前確認済：

- 既存 Asset/Asset_Milestone__c を参照する全 SOQL は explicit field指定（SELECT * 未使用）
- GCP側 Cloud Function (`product_engineering_agent.py`) の Asset SOQL も explicit
- 同名API `Actual_Amount__c` が `Sales_Agreement_Schedule__c` に既存だが、オブジェクトごとに独立スコープなので衝突なし
- 新規追加のみ、既存削除・改名なし

## 7. 将来拡張

- **Vertex AI による Projection 高度化**: `docs/concepts/asset-ltv-vertex-ai-projection.md`
  - 保守更新継続率・追加商談発生確率・信頼区間・ドライバー分解
  - 第一版の `projectStatic()` と切り替え可能な `projectWithVertexAi()` を `USE_VERTEX_AI` 環境変数で切り替える構成
- **Asset_Milestone__c Trigger**: Milestone CRUD 時に Asset の LTVサマリを自動更新（現状は手動スクリプト）
- **Opportunity 連携**: `Opportunity.Related_Asset__c` Lookup を追加すれば、Asset起点の追加販売実績/パイプラインを LTV に取り込める

## 8. 関連ファイル

| 種別 | パス |
|------|------|
| Apex | [force-app/main/default/classes/AssetLtvController.cls](../../force-app/main/default/classes/AssetLtvController.cls) |
| LWC | [force-app/main/default/lwc/assetLtvGcp/](../../force-app/main/default/lwc/assetLtvGcp/) |
| Milestone金額 | [force-app/main/default/objects/Asset_Milestone__c/fields/Planned_Amount__c.field-meta.xml](../../force-app/main/default/objects/Asset_Milestone__c/fields/Planned_Amount__c.field-meta.xml), [Actual_Amount__c.field-meta.xml](../../force-app/main/default/objects/Asset_Milestone__c/fields/Actual_Amount__c.field-meta.xml) |
| Asset LTV Summary | [force-app/main/default/objects/Asset/fields/](../../force-app/main/default/objects/Asset/fields/) |
| FlexiPage | [force-app/main/default/flexipages/Asset_BPS_Demo.flexipage-meta.xml](../../force-app/main/default/flexipages/Asset_BPS_Demo.flexipage-meta.xml) |
| 構想 | [docs/concepts/asset-ltv-vertex-ai-projection.md](../concepts/asset-ltv-vertex-ai-projection.md) |
