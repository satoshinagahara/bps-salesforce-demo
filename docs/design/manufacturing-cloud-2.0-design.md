# Manufacturing Cloud 2.0 設計構想

## コンセプト

需要変動 → BOM → サプライチェーン影響の**一気通貫可視化**。
単なる予実管理ではなく、需要変動を品質・調達・BOMデータと掛け合わせて**アクションに繋げる**のが本質。

---

## 全体アーキテクチャ: 3層パイプライン管理

製造業の営業〜受注管理を3つの時間軸で管理する。

| 層 | データソース | 時間軸 | 用途 |
|----|-------------|--------|------|
| 短期売上予測 | 通常商談（Opportunity） | 今期 | 直近の売上Forecast |
| 中長期パイプライン | Revenue_Forecast__c | 年度単位 | Design Win案件の加重予測 |
| 確定需要管理 | Sales_Agreement_Schedule__c | 月単位 | 契約済み製品の計画vs実績 |

---

## ライフサイクル

### Phase 1: Design Win営業活動（提案〜採用決定）

製造業では、同一商品を継続受注する前に**Design Win**（採用獲得）に向けた営業活動がある。
自動車部品でいえば、設計段階で採用が決まり、その後に長期供給契約へ移行する。

**Design Win商談は通常のパイプライン管理とは分離する。**
- Design Win商談のAmountはForecastに含めない（Omitted）
- 代わりに年度別子レコード（Revenue_Forecast__c）で中長期パイプラインを管理
- 子レコードは**品目×数量**を持つ → BOM展開でサプライチェーン準備に繋がる

#### 確度と連動するアクション

| 確度 | 営業アクション | 調達・製造アクション |
|------|--------------|-------------------|
| 25% | 提案・見積中 | — |
| 50% | 試作・評価中 | サプライヤーに非公式の打診 |
| 75% | 品質認定中 | RFQ発行・キャパ確認・工場計画開始 |
| 90% | 最終交渉 | 長期契約交渉・設備投資承認 |
| 100% | Design Win | Sales Agreement作成 → 月別Schedule移行 |

### Phase 2: Design Win → 長期契約への移行

Design Win商談がClosed Wonになったら：
1. Revenue_Forecast__c → Status「契約移行済」に一括更新
2. Sales_Agreement__c を自動作成（Source_Opportunity__c紐付け）
3. 年度予測額をベースにScheduleの初期値を按分セット

### Phase 3: 長期契約の需要管理（計画 vs 実績）

Sales Agreementの月別Scheduleで確定需要を管理。
- 計画数量/金額 vs 実績数量/金額
- 乖離分析 → 根因調査 → アクション

---

## データモデル

### Opportunity（Design Win）

RecordType「Design Win」で通常商談と完全分離。

- ForecastCategoryName: **Omitted**（売上予測から除外）
- Amount: null または参考値
- 専用ステージ:
  - 引合い(10%) → 提案(25%) → 試作・評価(50%) → 品質認定(75%) → 最終交渉(90%) → Design Win(100%) / 失注(0%)

### Revenue_Forecast__c（年度別受注予測）★新規

Design Win商談の子レコード。**品目×数量×年度**で中長期パイプラインを構成。

| フィールド | 型 | 説明 |
|-----------|-----|------|
| Opportunity__c | MD → Opportunity | 親のDesign Win商談 |
| Product__c | Lookup → Product2 | 対象品目 |
| Fiscal_Year__c | Picklist / Text | 対象年度（FY2026等） |
| Forecast_Quantity__c | Number | 年間予測数量 |
| Unit_Price__c | Currency | 想定単価 |
| Forecast_Amount__c | Formula | 数量 × 単価 |
| Probability__c | Formula | 親商談のProbabilityを参照 |
| Weighted_Amount__c | Formula | 金額 × 確度 |
| Status__c | Picklist | 予測中 / 契約移行済 / 失注 |

**品目と数量を持つことの意義:**
- BOM展開 → 部品別の必要数量算出 → サプライヤー別の総需要把握
- 確度が上がるにつれ、サプライヤーとの事前ネゴ・工場リソース手配が可能に

### Sales_Agreement__c（販売契約）★新規

Design Win後に作成される長期供給契約。

| フィールド | 型 | 説明 |
|-----------|-----|------|
| Account__c | Lookup → Account | 顧客 |
| Source_Opportunity__c | Lookup → Opportunity | 獲得元のDesign Win商談 |
| Contract_Start__c | Date | 契約開始日 |
| Contract_End__c | Date | 契約終了日 |
| Status__c | Picklist | 有効 / 更新交渉中 / 終了 |

### Sales_Agreement_Product__c（契約製品）★新規

| フィールド | 型 | 説明 |
|-----------|-----|------|
| Sales_Agreement__c | MD → Sales_Agreement__c | 親契約 |
| Product__c | Lookup → Product2 | 対象製品 |
| Unit_Price__c | Currency | 契約単価 |

### Sales_Agreement_Schedule__c（月別スケジュール）★新規

| フィールド | 型 | 説明 |
|-----------|-----|------|
| Sales_Agreement_Product__c | MD → Sales_Agreement_Product__c | 親の契約製品 |
| Schedule_Month__c | Date | 対象月 |
| Plan_Quantity__c | Number | 計画数量 |
| Plan_Amount__c | Currency | 計画金額 |
| Actual_Quantity__c | Number | 実績数量 |
| Actual_Amount__c | Currency | 実績金額 |

### Supplier_Capacity__c（供給キャパシティ）★新規

拠点×部品の月産上限を管理。What-ifシミュレーション時のキャパシティ突合、災害時のオフロード提案に使用。

| フィールド | 型 | 説明 |
|-----------|-----|------|
| Manufacturing_Site__c | MD → Manufacturing_Site__c | 生産拠点 |
| Part_Number__c | Text(50) | 部品番号（BOM_Part__c.Part_Number__cと一致） |
| Part_Name__c | Text(100) | 部品名 |
| Monthly_Capacity__c | Number | 月産上限数量 |
| Effective_From__c | Date | 有効開始日 |
| Effective_To__c | Date | 有効終了日 |
| Notes__c | LongTextArea | 備考 |

---

## データチェーン全体像

```
Opportunity (Design Win)
  └─ Revenue_Forecast__c（品目 × 数量 × 年度）
       └─ Product2 → BOM_Header__c → BOM_Line__c → BOM_Part__c
            └─ Account（サプライヤー）
                 ├─ Supplier_Audit__c（監査状況）
                 ├─ Supplier_Certification__c（認証状況）
                 ├─ RFQ__c（見積依頼）
                 └─ Manufacturing_Site__c（製造拠点）
                      └─ Supplier_Capacity__c（供給キャパシティ）

  ──── Design Win達成 ────

Sales_Agreement__c（Source_Opportunity__c で紐付け）
  └─ Sales_Agreement_Product__c
       └─ Sales_Agreement_Schedule__c（月別 計画 vs 実績）
            └─ 同じProduct2 → 同じBOMチェーン
```

**提案段階から契約後まで、品目を軸に一本で繋がる。**

---

## LWC（計画）

| LWC | 配置先 | 機能 | 状態 |
|-----|--------|------|------|
| `salesAgreementChart` | Sales_Agreement__cレコードページ | 月別の計画vs実績バーチャート | 実装済み |
| `salesAgreementScheduleGrid` | Sales_Agreement__cレコードページ | 月別スケジュール編集グリッド | 実装済み |
| `accountForecastPanel` | Accountレコードページ | 顧客の全契約を集約したフォーキャスト（SA/DW/通常の3タブ） | 実装済み |
| `demandImpactAnalysis` | Sales_Agreement__cレコードページ | 乖離分析 + What-ifシミュレーション（BOM展開→サプライヤー影響→キャパシティ突合→AI洞察） | 実装済み |
| `revenueForecastEditor` | Design Win商談ページ | 品目×四半期の数量・単価グリッド編集 | 実装済み |
| `designWinConversion` | Design Win商談ページ | DW→販売契約変換（SA+製品+空Schedule自動生成） | 実装済み |
| `salesDemandDashboard` | ホームページ | 全社営業需要ダッシュボード | 実装済み |
| `supplierDemandOutlook` | サプライヤーAccountページ | 供給側から見た需要（BOM逆引き→確定需要/パイプライン）+ キャパアラート | 実装済み |

---

## Agentforce ユースケース（計画）

### 1. What-if 需要変動シミュレーション

```
ユーザー: 「顧客Aの電力変換モジュール案件、確度が75%に上がった。影響は？」

Agent:
  1. Revenue_Forecast__c取得 → 製品A × 12,000台/年
  2. BOM展開 → 部品リスト × 数量算出
  3. 既存Sales Agreementの計画数量と合算
  4. サプライヤー別の総需要量を算出
  5. 供給キャパ・監査状況・認証期限と照合
  → 「東亜電子の部品Xが供給上限に近づきます。事前交渉を推奨。」
```

### 2. 需要乖離アラート＋根因分析

乖離が大きい契約を検出 → 同顧客のケース・活動・品質データを横断確認。

### 3. サプライチェーンキャパシティチェック

全契約の計画数量 → BOM展開 → 供給リスクのある部品を特定。

---

## 実装順序

1. **オブジェクト＋デモデータ** — 5オブジェクト作成、顧客3〜4社にDesign Win商談+年度予測+販売契約（12ヶ月分スケジュール、意味のある乖離パターン）
2. **LWC** — 3つのコンポーネント
3. **Agentforce What-if分析** — Employee Agentに新トピック追加

---

## 既存資産との連携

- **BOM**: 製品→BOM展開で部品・サプライヤーまで辿れる（既存10商品×13 BOMヘッダー）
- **RFQ**: 調達コスト見積との突合（確度75%以上でRFQ発行）
- **Design_Project__c**: 試作・評価フェーズで設計開発プロジェクトが走る
- **品質管理**: CA/SI情報でサプライヤーの品質リスク加味
- **サプライヤー監査/認証**: 供給能力・信頼性の評価
- **製造拠点**: 自社工場のキャパシティ考慮

---

*最終更新: 2026-03-14*
