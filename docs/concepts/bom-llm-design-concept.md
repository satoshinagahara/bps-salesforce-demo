# BOM標準化 × LLM活用 設計コンセプト

**目的**：製造工程BOM（Excel/CSV）をSalesforce（SoE）向けにシンプル化・標準化し、サプライヤーコミュニケーションの原資として活用する  
**作成日**：2026-03-18  
**ステータス**：Phase 2 完了（2026-03-21） → Phase 3 精度測定・閾値調整

### 準備済みアセット
- 製品: `EG-3000 EnerGrid 産業用ハイブリッド蓄電システム`（Product2 ID: 01tIe000002ImkKIAS）
- サンプル製造BOM CSV: `data/bom_energrid_eg3000_manufacturing.csv`
  - 全48行（調達部品約32行、不要ノード8行、階層ヘッダー8行）
  - サプライヤー表記揺れ19パターン（㈱/株式会社/(株)/英語/略称/中黒等）
  - 不要ノード8件（工程費、治具費、検査工程、ソフト開発費等）
  - 備考欄に埋もれた情報（代替品、サプライヤー名、未確定情報）
- Prompt Template: `BOMSupplierMatching`（BOMサプライヤー名寄せ）
- Apexクラス: `BOMSupplierMatchingAction`（CSV解析→マスタ照合→LLM呼び出し）
- Apexバッチ: `BOMSupplierMatchingBatch`（Data Cloud→LLM名寄せ→BOMオブジェクト書き込み）
- バッチランチャー: `BatchLauncherController` に「BOM → サプライヤー名寄せ」登録済み
- S3コネクタ: `BOM S3`（バケット: `snagahara-poc-.../bom-files/`）
- Data Cloud: DLO `csv_BOM_S3` → DMO（カテゴリ: その他、PK: 品目コード）

### Phase 0 検証結果（2026-03-21）

Prompt Template `BOMSupplierMatching` + GPT-4o mini で購買部品29行を一括名寄せ実行。

| 信頼度 | 件数 | 内訳 |
|--------|------|------|
| **High** | 26件 | 全件正確にマッチ（誤判定0件） |
| **Mid** | 0件 | — |
| **Low** | 3件 | 通信キャリア直接契約 / アキバ電子パーツ / 空調メーカーA（全件適切なnull判定） |

**対応できた表記揺れパターン**：
- 法人格の違い: ㈱ / (株) / 株式会社 → 正規名
- 略称: 東亜電子 → 東亜電子工業、富士精密 → 富士精密機械
- ローマ字: toa-denshi → 東亜電子工業、Fuji Seimitsu Co. → 富士精密機械
- 英語↔日本語: Allied Power → アライドパワー株式会社、Green Energy Cell → グリーンエナジーセル
- 中黒の有無: サンライズ・ディスプレイ → サンライズディスプレイ、アライド・パワー → アライドパワー
- ズの有無: 日本マテリアル → 日本マテリアルズ
- 備考欄活用: toa-denshi（備考「東亜電子さんに発注」）→ 東亜電子工業

**所感**：GPT-4o miniでも日本語名寄せの精度は十分高い。Few-shotを明示的に組み込まなくてもルールベースの指示だけで全パターン正解。Phase 1ではMid判定の閾値設計とStaging→本オブジェクト書き込みフローの構築が焦点。

---

## 1. 背景と要件整理

### 1.1 解決したい問題

- 製造工程で使われるBOMはサプライヤー情報・発注部品などの情報を持つが、Salesforceのようなリレーション管理・コミュニケーション用途（SoE）に直接取り込めるフォーマットではない
- BOMには複雑な工程情報・多階層構造・表記揺れが含まれており、Salesforceが必要とする粒度への変換が必要

### 1.2 Salesforce側で知りたいこと（最低限）

- ある製品を作るのに、**どの部品が何個必要か**
- その部品を**どのサプライヤーに発注しているか**
- 工程順序・製造パラメータ・内製加工情報は**不要**

### 1.3 前提条件

| 項目 | 内容 |
|------|------|
| BOMソース | Excel / CSV |
| サプライヤーマスタ | Salesforce内に存在 |
| LLM実行環境 | Salesforce内（Prompt Templateから呼び出し） |
| LLM選択肢 | OpenAI / Anthropic / Google Gemini（Salesforceのトラストレイヤーで保護） |
| セキュリティ | Salesforce側で担保（Zero Data Retention等） |
| Einstein（組み込み）| **対象外**（LLMではないため） |

---

## 2. 処理方針

### 2.1 基本原則

| 原則 | 内容 |
|------|------|
| LLMに数値計算させない | 数量集計・合算はコード側で完結させる |
| LLMは「候補生成」に限定 | 最終的な確定判断はコード（閾値）または人間が行う |
| Stagingを挟む | 本オブジェクトへの書き込み前に必ず仮置き層を経由する |
| 信頼度で処理を分岐 | 自動化・半自動・手動の3段階を設ける |

### 2.2 LLMが担う処理・担わない処理

**LLMが担う（意味解釈・名寄せ）**

- 部品名・サプライヤー名の表記揺れ吸収
- サプライヤーマスタ候補とのマッチング判定
- 備考・コメント欄からのサプライヤー情報抽出
- 不要ノード（工程内仕掛品・内製加工費等）の除外判断

**コードが担う（計算・照合・制御）**

- 多階層BOMのフラット化・展開
- 品目ごとの数量集計・合算
- SOQLによるサプライヤーマスタ候補の事前絞り込み
- 信頼度スコアによる処理分岐
- Salesforce本オブジェクトへの書き込み

---

## 3. アーキテクチャ

### 3.1 暫定案：S3 + Data Cloud パターン（2026-03-21）

アンケートパイプライン（S3 → Data Cloud → Apex）の構成を流用し、Salesforce外部にPython/ETLツールを置かない方針。未検証のため暫定。

```
 Excel / CSV（製造BOM）
      ↓ 手動アップロード
 S3バケット (bom-files/)
    - 既存の S3コネクタ IAMユーザー (datacloud-s3-reader) を再利用
      ↓ Data Cloud S3データストリーム（増分同期）
 Data Cloud DLO/DMO（BOM Staging）
    - カテゴリ: Engagement（ID解決不要）
    - CSVの全カラムをそのまま取り込み
    - フラット化・数量集計はApex側で処理
      ↓ Data Cloud queryv2 API
 Apex: BOMデータ取得 + Accountマスタ照合
      ↓
 Prompt Template → LLM呼び出し（BOMSupplierMatching）
    - 入力：BOM部品リスト + Accountマスタ候補
    - 出力：マッチング候補 + 信頼度ラベル（High / Mid / Low）
      ↓
 Apex: 信頼度分岐
    ┌─ High → 自動で本オブジェクトに書き込み
    ├─ Mid  → レビュー画面に表示（担当者が1クリック承認）
    └─ Low  → 手動対応キューに積む
      ↓
 BOMオブジェクト確定（品目 / 数量 / サプライヤー）
    → サプライヤーコミュニケーションの原資として活用
```

> **未検証事項**: BOM用データストリームの新規作成手順・工数は未確認。アンケートパイプラインではDLOカテゴリ選択やDMOマッピングで試行錯誤があったため（→ `docs/reference/data-cloud-lessons-learned.md`）、同様の作業が発生する見込み。

### 3.2 当初案：外部ETL パターン（参考）

当初の設計。Salesforce外にパース処理を持つ構成。Excel直接読み込みや数万行規模で必要になる可能性あり。

```
【Salesforce外】
 Excel / CSV → ① Python or ETLツールで構造パース・フラット化
              → ② Salesforce Staging オブジェクトへ仮Import
───────────────────────────────────
【Salesforce内】
 ③ SOQL事前絞り込み → ④ LLM名寄せ → ⑤ 信頼度分岐 → ⑥ 確定
```

---

## 4. Prompt Template 設計方針

### 4.1 基本構造

```
【System】
あなたはBOMデータのサプライヤーマッチングアシスタントです。
以下のルールに従ってください：
- 必ずJSON形式で返答する
- 判断できない場合は confidence: "Low" を返す
- 数量の計算は行わない

【User】
部品名：{staging_part_name}
サプライヤー候補：
  1. {candidate_1}
  2. {candidate_2}
  3. {candidate_3}

上記候補の中から最も近いものを選び、以下のJSON形式で返答してください：
{
  "matched_supplier_id": "SFID or null",
  "matched_supplier_name": "名称 or null",
  "confidence": "High / Mid / Low",
  "reason": "判断理由を簡潔に"
}
```

### 4.2 Few-shot例の組み込み（推奨）

表記揺れのパターンをPrompt Templateに正例・負例として埋め込む。  
例：「㈱山田製作所」→「山田製作所株式会社」は一致、「山田金属㈱」とは別、など。

---

## 5. モデル選定の考え方

| モデル | 向いているケース |
|--------|----------------|
| Claude Sonnet / GPT-4o | 日本語表記揺れが複雑・曖昧な記述が多い場合 |
| Gemini Flash / GPT-4o mini | 大量レコード処理でコストを抑えたい場合 |

**推奨方針**：まずClaude SonnetまたはGPT-4oでPoC（精度検証）→大量処理フェーズでコスト最適化を検討。

---

## 6. 技術的注意点

### 6.1 Apex Governor Limits（確度：中・要検証）

- 同期Callout：1トランザクションあたり100件制限
- 大量BOM処理は**Batchable Apexで分割実行**する設計が必要
- Queueable Apexを使ったチェーン実行も選択肢

### 6.2 トークンコスト管理

- BOM 1行ずつ処理する設計を基本とする
- 1プロンプトに複数行をまとめる場合は入力トークン数を見積もること
- サプライヤー全件をプロンプトに渡さない（SOQLで事前絞り込みが前提）

### 6.3 信頼度閾値の設計

- 初期は閾値を保守的に設定し、**Midの割合を多めにしてレビューで学習**する
- 一定期間の運用後に、誤りパターンを分析して閾値とFew-shotを改善するサイクルを設ける

---

## 7. 残課題・確認事項

### 7.1 解決済み

| # | 確認事項 | 結論 |
|---|----------|------|
| 1 | Staging用オブジェクトの方式 | Data Cloud DLO/DMOをStaging層として活用（カスタムオブジェクト不要） |
| 2 | CSV Import のETL | S3 + Data Cloudデータストリームで完結（外部ETL不要） |
| 4 | サプライヤーマスタの検索方式 | Account全件をプロンプトに渡してLLMが判断（SOQL事前絞り込み不要だった） |
| 6 | Few-shot用の正例・負例 | ルールベースの指示だけで全パターン正解（Few-shot不要だった） |

### 7.2 未解決

| # | 確認事項 | 影響範囲 |
|---|----------|----------|
| 3 | BOM 1ファイルあたりの行数規模感 | 大規模BOMでのトークン上限・バッチ分割設計 |
| 5 | Mid/Low判定時のレビューフロー | 業務フロー設計・BOM編集UI |

### 7.3 CSV → Salesforce ギャップ一覧（2026-03-21 時点）

Phase 1パイプライン実装により判明したギャップ。優先度順に対応予定。

| 優先度 | ギャップ | 現状 | 対応案 |
|--------|----------|------|--------|
| **P1** | BOM編集UI（LWC） | 既存 `bomTreeViewer` に信頼度列＋サプライヤー変更アクションを追加済み | ✅ 対応済み（Phase 1.5） |
| **P1** | BOM_SubComponent__cの階層化 | Assembly毎に仮1件。CSVに「サブコンポーネント」概念なし | LLMに部品グルーピングを判断させるか、BOM編集UIで手動整理 |
| **P1** | サプライヤー拠点（Manufacturing_Site__c）の自動紐付け | BOM名寄せでSupplier__cのみ設定。拠点は空のまま | → 7.4 参照 |
| **P1** | 代替BOM（セカンダリBOM）の作成フロー | CSVから入ってくるBOMがプライマリか代替か判別不能 | → 7.5 参照 |
| **P2** | 備考欄の構造化情報 | 「代替: CATLセル」「公差±0.1mm」等がテキストのまま | LLMで `Alternative_Part__c`、`Tolerance__c` 等に分解（Prompt追加） |
| **P2** | 内製部品の取り込み | 購買品のみ取り込み。内製部品（高圧ケーブル等）は除外 | `Make_or_Buy__c = '内製'` も取り込むよう改修 |
| **P3** | 外注加工費の扱い | 品目コード空の行（塗装費等）が除外 | 必要に応じて品目コード自動採番で取り込み |
| **P3** | CSVカラム名のハードコード | API名 `default_0__c` 〜 `default_10__c` 固定 | カラムマッピング設定を外部化（カスタムメタデータ等） |
| **P3** | BOM_Line__c の Component_Product__c | Assembly行にProduct2紐付けなし | Product2にAssembly製品を事前登録 or 無視 |

### 7.4 サプライヤー拠点の自動紐付け設計（2026-03-21 検討）

#### 問題

BOM名寄せバッチは `Supplier__c`（Account）のみをLLMで紐付けているが、`Manufacturing_Site__c`（製造拠点）は空のまま。この空白により以下の下流機能が動作しない：

- **需要変動インパクト分析**（`DemandImpactController`）：Supplier_Capacity__cとの結合にManufacturing_Site__cが必要
- **災害シミュレーション**（`ManufacturingSiteMapController`）：Prefecture__cで被災サイトを特定するためManufacturing_Site__cが必要
- **サプライヤー需要見通し**（`SupplierDemandController`）：拠点別の需要集計

#### 現状データ

複数拠点を持つサプライヤーが5社（グリーンエナジーセル、テクノコネクト、東亜電子工業、日本マテリアルズ、富士精密機械）。同一品目を複数拠点で製造するケースもある（例：富士精密機械 P-HC-001 → 長野工場・浜松工場の両方にキャパシティあり）。

#### 決定：サプライヤー品目マスタ `Supplier_Part__c` の新設

| 方式 | 評価 |
|------|------|
| ~~Supplier_Capacity__cに`Is_Primary__c`追加~~ | ❌ 新品目が入ってきた時にCapacityレコードがなければ拠点解決不可 |
| ~~Manufacturing_Site__cにプライマリフラグ~~ | ❌ サプライヤー単位の粒度では不十分（東亜電子：ICは本社、パワー半導体は九州） |
| **`Supplier_Part__c` 新規オブジェクト** | ✅ 品番×サプライヤー×デフォルト拠点の粒度で管理。既存BOM構造への影響なし |

```
Supplier_Part__c（新規）
  ├─ Supplier__c → Account（サプライヤー）
  ├─ Part_Number__c（品番）
  ├─ Part_Name__c（品名）
  ├─ Default_Site__c → Manufacturing_Site__c（プライマリ製造拠点）
  └─ （その他：リードタイム、メーカー品番等はBOM_Part__cから参照）
```

**名寄せフロー**：
1. LLMでSupplier__c（Account）を特定
2. Supplier_Part__cからPart_Number__c + Supplier__cでデフォルト拠点を取得
3. 見つかれば Manufacturing_Site__c に自動設定、見つからなければ空（手動設定対象）

### 7.5 代替BOM（セカンダリBOM）の作成フロー（2026-03-21 検討）

#### 問題

同一製品に対して複数BOMが存在する（例：高容量リチウムイオン電池 → 浜松工場向けBOM + 京都工場向け代替BOM）。CSVから2つ目のBOMが入ってきた時、プライマリか代替か判別できず、同じ拠点が設定されてしまう。

#### 検討した3案

| 案 | 内容 | 評価 |
|----|------|------|
| A: もう一つCSVが飛んでくる | 2つ目のCSVで代替BOM作成 | ❌ 代替BOMかどうか判別不能。同じ拠点が入る |
| B: Salesforce上でBOMコピー | 既存BOMをコピーし拠点だけ変更 | ◯ 明示的だがUI実装が必要。Phase 2以降 |
| **C: CSV拠点列追加** | CSVに「拠点」列を追加。空ならプライマリ、入っていればサプライヤー名寄せと同等ロジックで拠点導出 | **✅ 採用（推奨）** |

#### 決定方針：CSV拠点列追加 + 将来的にSF上コピー

- **CSV列追加**：「サプライヤー/調達先」の隣に「拠点」列を1つ追加
  - 空欄 → Supplier_Part__cのデフォルト拠点を使用（プライマリBOM）
  - 値あり → LLMで Manufacturing_Site__c の名寄せを実行（代替BOM）
  - 同一製品 × 異なる拠点 → 別の BOM_Header__c として作成
- **SF上コピー**（Phase 2以降）：BOM_Header__cのコピー機能をLWCに追加。コピー後にサプライヤー拠点を変更するワークフロー

### 7.6 Sales_Agreement_Product__c → BOM_Header__c の紐付けとBOM配分（2026-03-21 検討・拡張）

#### 問題

現在 `Sales_Agreement_Product__c` は `Product__c`（Product2）のみ持っている。同一製品に複数BOMがある場合（例：高容量リチウムイオン電池 → 浜松BOM / 京都BOM）、どのBOMベースの契約なのか判別できない。

`DemandImpactController` はSales_Agreement → Product → BOM_Header__c → BOM展開という流れで需要を部品レベルに展開するが、BOMが複数あると「どのBOMで展開すべきか」が不明。拠点もサプライヤーキャパシティも異なるため、誤ったBOMで展開すると需要変動インパクト分析の精度に直結する。

#### 対応案

`Sales_Agreement_Product__c` に `BOM_Header__c` へのLookupフィールドを追加（実装済み）。

```
Sales_Agreement_Product__c（既存）
  ├─ Product__c → Product2（既存）
  ├─ BOM_Header__c → BOM_Header__c（追加済み）← どのBOMで需要展開するか
  └─ Unit_Price__c, ...
```

#### BOM配分（拠点オフロード）の運用

同一製品に対して複数BOMを持つ場合、**1契約製品=1BOM**の原則で、契約製品を行分割して配分する。

```
通常時:
  高容量リチウムイオン電池 月100台 → 全量 浜松BOM

リスク分散（拠点オフロード）:
  高容量リチウムイオン電池 月60台 → 浜松BOM（行1）
  高容量リチウムイオン電池 月40台 → 京都BOM（行2）

災害発生時（浜松被災）:
  高容量リチウムイオン電池 月100台 → 全量 京都BOMに切替
```

災害シミュレーション（`ManufacturingSiteMapController`）の被災影響・代替拠点提案 → 契約製品のBOM配分変更、という導線が成立する。

#### BOM配分LWC（契約製品 × BOM設定）

Sales_Agreement__cレコードページに配置。3つの操作を提供：

1. **一覧表示**: 契約製品ごとにBOM・組立拠点・月別数量を表示。未設定は警告
2. **BOM割当**: 未設定の契約製品にBOMを選択（モーダルでBOM候補をカード表示）
3. **行分割**: 既存の契約製品を2行に分割し、異なるBOMを割り当てる。スケジュール（月別数量）も配分比率で自動分割

> **注意**: 受注予測（Revenue_Forecast__c）→ 契約変換の導線は営業側の持ち物のため、BOM要素は入れない。BOM配分は契約確定後に生産管理側がこのLWCで設定する運用。

---

## 8. 実装フェーズ案

| フェーズ | 内容 | 目標 |
|----------|------|------|
| **Phase 0** | サンプルBOMで名寄せ検証 — ✅ **完了** | 29件中26件High（全件正確）、Low3件（適切なnull判定） |
| **Phase 1** | パイプライン実装 — ✅ **完了** | S3→Data Cloud→LLM名寄せ→BOMオブジェクト書き込みの一気通貫 |
| **Phase 1.5** | BOM編集UI — ✅ **完了** | 既存bomTreeViewerに信頼度列＋サプライヤー変更アクション統合 |
| **Phase 2** | 拠点紐付け + SA→BOM紐付け — ✅ **完了** | Supplier_Part__c新設、拠点自動紐付け、BOM配分LWC、DemandImpact改修 |
| **Phase 3** | シミュレーション連動・BOM運用機能 — **次のステップ** | 災害シミュ→What-If→BOMコピー→配分変更の一気通貫 |
| **Phase 4** | データ品質・拡張 | 備考欄構造化、内製部品取り込み、精度測定 |
| **Phase 5** | 本番展開・スケール | 全BOMデータへの適用・運用ルーティン化 |

### Phase 3 計画

シミュレーション結果からリスク対策を実行に移すための一連の機能。

```
災害シミュレーション（被災拠点特定）
  → DemandImpact What-If（需要量への影響定量化）← 災害シミュに需要量統合
    → 「浜松BOMの供給が月10,000台不足。京都BOMなら代替可能」
      → BOMコピー（浜松BOM → 京都工場向けに複製・拠点変更）← 新規
        → BOM配分LWCで契約製品を分割（浜松60台 + 京都40台）← 実装済み
          → DemandImpactで再シミュレーション → 供給充足確認
```

| Step | 内容 | 概要 |
|------|------|------|
| Step 1 | 災害シミュレーションへの需要量統合 | ManufacturingSiteMapControllerに販売契約の月間需要量を統合。「被災で月間X台の供給停止、代替で月間Y台カバー可能、差分Z台が供給不足」まで定量化 |
| Step 2 | BOMコピー機能（LWC） | bomTreeViewerまたはProduct2ページにコピーボタン追加。元BOMを複製し、組立拠点・サプライヤー拠点を一括変更。What-If結果からの導線を確保 |
| Step 3 | What-If → BOMコピー → 配分変更の導線接続 | demandImpactAnalysis LWCの結果画面から「代替BOM作成」アクションを追加。BOMコピー→配分LWCへの自然な遷移 |

### Phase 1 実装結果（2026-03-21）

バッチランチャーから「BOM → サプライヤー名寄せ」を実行し、以下のレコードが自動生成された。

| オブジェクト | 件数 | 備考 |
|---|---|---|
| BOM_Header__c | 1件 | EnerGrid → ステータス「設計中」 |
| BOM_Line__c | 5件 | Assembly単位（蓄電池/PCS/BEMS/筐体/配線） |
| BOM_SubComponent__c | 5件 | Line毎に仮1件 |
| BOM_Part__c | 26件 | サプライヤー紐付き23件 / 未紐付3件（Low判定: アキバ電子パーツ、通信キャリア直接契約、空調メーカーA） |

### Phase 2 Step 1〜3 実装結果（2026-03-21）

#### Step 1: Supplier_Part__c 新設
- オブジェクト `Supplier_Part__c`（サプライヤー品目）を作成
- フィールド: Supplier__c（Account）、Part_Number__c、Part_Name__c、Default_Site__c（Manufacturing_Site__c）
- 既存Supplier_Capacity__cから86件の初期データ投入（キャパシティが最大の拠点をデフォルト設定）

#### Step 2: CSV拠点列追加 + Data Cloud再設定
- CSVに「製造拠点」列を追加（サプライヤー/調達先と内外区分の間）
- S3再アップロード → Data Cloudデータストリーム再作成（12カラム）
- CSVのサプライヤー修正: アライドパワー株式会社（拠点未登録）の品目を適切なサプライヤーに変更
  - 板金系（ラック、ドアパネル）→ 日本マテリアルズ
  - 絶縁トランス → 東亜電子工業
  - 制御ケーブル → テクノコネクト

#### Step 3: 名寄せバッチ改修
- Data Cloud queryv2のカラムマッピング更新（データストリーム再作成でAPI名が変更）
- 製造拠点の自動解決ロジック追加:
  1. CSV拠点列に値あり → Manufacturing_Site__c名前マッチ
  2. CSV拠点列が空 → Supplier_Part__cのデフォルト拠点を使用
  3. Supplier_Part__c未登録の新品番 → 自動登録（サプライヤーの最初の拠点を仮設定）
- Data Cloud queryv2の行順序非保証への対応（品目コードプレフィックスでAssembly判定）

**最終結果**: 29件中26件にサプライヤー＋拠点が自動紐付け。Low判定3件は手動設定対象。

### Phase 2 Step 4〜6 実装結果（2026-03-21）

#### Step 4: Sales_Agreement_Product__c → BOM_Header__c Lookup追加 + BOM配分LWC
- `Sales_Agreement_Product__c` に `BOM_Header__c` Lookupフィールドを追加
- BOMが1つの製品は自動設定（1件）。複数BOMの製品（3製品）は手動設定対象
- **BOM配分LWC（`bomAllocation`）** を作成し、Sales_Agreement__cレコードページに配置
  - 一覧表示: 契約製品ごとにBOM・組立拠点・月間数量・設定状態を表示
  - BOM選択モーダル: BOM候補をカード形式で表示（部品数・サプライヤー数・組立拠点）
  - 行分割モーダル: スライダーで配分比率を指定 → 契約製品を2行に分割 + スケジュール自動按分
- **BOM配分の運用コンセプト**: 同一製品に複数BOMを持つ場合、契約製品を行分割してBOM配分する。災害シミュレーションの結果→契約製品のBOM配分変更という導線が成立

#### Step 5: DemandImpactController改修
- `expandBOM()` メソッドを改修:
  - BOM_Header__c指定あり → そのBOM IDのみで部品検索（拠点別に正確な展開）
  - BOM_Header__c指定なし → 従来通りProduct__c + 承認済みで検索（後方互換）
- `getImpactData()` / `simulateWhatIf()` で `Sales_Agreement_Product__c.BOM_Header__c` を取得し、expandBOMに渡す

#### Step 6: 統合テスト
- **getImpactData** ✅ — BOM指定ありで5サプライヤー・9部品が正しく展開
- **simulateWhatIf（+20%）** ✅ — キャパシティアラート正常検出（東亜電子 P-GD-001: 110.6%、P-MCU-001: 106.2%）
- **後方互換** ✅ — BOM未設定の場合は従来通り動作
