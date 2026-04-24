# IDP擬似実装 — サプライヤー見積書取り込み設計書

**実装完了日**: 2026-04-24
**ステータス**: **実装完了(Phase 1-4 + サンプルデータ)**、Phase 5-8 は将来拡張
**機能**: Mulesoft IDP(Intelligent Document Processing)相当機能の擬似実装
**対象ユースケース**: サプライヤーから返却された見積書PDFを Salesforce にD&Dでアップすると、裏の擬似IDP(マルチモーダルLLM)が項目値を抽出し、担当者入力値と1:1比較・差分評価を行う

---

## 1. 背景と目的

### 1.1 Mulesoft IDP の擬似再現

Mulesoft IDP は非構造/半構造ドキュメントから事前定義スキーマに基づきAI抽出し、JSONを返す機能。信頼度スコア付与とHuman-in-the-loopが特徴。本デモはライセンス無しのため **Claude Sonnet 4.6(マルチモーダル)を外部Lambda経由で呼び出す擬似IDP** で同等のUX/価値を再現する。

### 1.2 業務シナリオ

BPSの購買担当が `RFQ__c`(購買見積依頼) を発行 → サプライヤーから見積書PDFが返送される → 購買担当が `RFQ_Quote__c`(購買見積回答) に手入力 → **本機能**でPDFをD&Dアップロード → 擬似IDPが項目値を抽出 → 担当者入力値と並列表示 → 相違判定 → 監査ログとして確認メモを記録。

### 1.3 基本方針: AIは参考値

**AI抽出値は「担当者入力の誤りへの気づきを与える参考値」として位置づける。** 「AI入力が正」という運用方針は取らない。最終判断は常に担当者が行う。致命差と判定された場合でも **AIが誤っている可能性** があり、担当者が根拠を確認した上で、**致命差を残したまま "担当者確認済" に遷移させることを許容** する。その際、担当者は確認メモを自由入力で残し、監査ログとする。

---

## 2. アーキテクチャ

### 2.1 全体構成

```
┌──────────────────────────────────────────────────────────────────┐
│ Salesforce (trailsignup-61aa736aacb04f)                           │
│                                                                     │
│  ┌────────────────────────┐  ┌────────────────────────┐          │
│  │ idpQuoteFileUploader   │  │ idpQuoteDualEntry       │          │
│  │ (LWC - File Upload)    │  │ (LWC - Compare+Review)  │          │
│  └──────────┬─────────────┘  └──────┬──────────────────┘          │
│             │                        │                              │
│             ▼                        ▼                              │
│  ┌──────────────────────────────────────────┐                      │
│  │ IdpSupplierQuoteController (Apex)         │                      │
│  │ getPresignedUrl / initializeIdpRecord /   │                      │
│  │ startExtraction / getIdpStatus /          │                      │
│  │ getFullRecord / startJudgment /           │                      │
│  │ markAsConfirmed / clearIdpResult          │                      │
│  └───────┬────────────────────┬──────────────┘                     │
│          │ callout            │ ConnectApi                          │
│          │                    ▼                                     │
│          │         ┌──────────────────────────┐                    │
│          │         │ GenAiPromptTemplate       │                    │
│          │         │ IDP_Supplier_Quote_Judge  │  (Claude 4.6)     │
│          │         └──────────────────────────┘                    │
│          │                                                          │
│          │ ┌────────────────┐                                      │
│          │ │ RFQ_Quote__c   │ ← Object (37 shadow fields added)    │
│          │ └────────────────┘                                      │
└──────────┼──────────────────────────────────────────────────────────┘
           │
           ▼ HTTPS (API Gateway)
┌──────────────────────────────────────────────────────────────────┐
│ AWS (ap-northeast-1, account 938145531465)                         │
│                                                                     │
│  ┌─────────────────┐  ┌─────────────────────┐                     │
│  │ bps-demo-idp-   │  │ bps-demo-idp-       │                     │
│  │ presign (zip)   │  │ extract-dispatcher  │                     │
│  └────────┬────────┘  │ (zip)               │                     │
│           │           └──────┬──────────────┘                     │
│           │                  │ invoke async                        │
│           ▼                  ▼                                     │
│  ┌──────────────────────────────────────┐                         │
│  │ bps-demo-idp-extract (Container/ECR)  │                         │
│  │ - Download PDF from S3                │                         │
│  │ - Call Claude Sonnet 4.6 tool_use    │                         │
│  │ - JWT → Salesforce REST API PATCH     │                         │
│  └────┬─────────────────────┬────────────┘                        │
│       │                     │                                      │
│       ▼                     ▼                                      │
│  ┌──────────┐      ┌────────────────┐                             │
│  │ S3       │      │ Anthropic API  │                             │
│  │ (idp-    │      │ (外部)          │                             │
│  │  prefix) │      └────────────────┘                             │
│  └──────────┘                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 コンポーネント一覧(as-implemented)

| レイヤ | コンポーネント | 種別 | ファイル/リソース |
|---|---|---|---|
| UI | `idpQuoteFileUploader` | LWC | [force-app/main/default/lwc/idpQuoteFileUploader/](../../force-app/main/default/lwc/idpQuoteFileUploader/) |
| UI | `idpQuoteDualEntry` | LWC | [force-app/main/default/lwc/idpQuoteDualEntry/](../../force-app/main/default/lwc/idpQuoteDualEntry/) |
| Apex | `IdpSupplierQuoteController` | Apex class + test | [force-app/main/default/classes/IdpSupplierQuoteController.cls](../../force-app/main/default/classes/IdpSupplierQuoteController.cls) |
| LLM (判定) | `IDP_Supplier_Quote_Judge` | Prompt Template (Flex) | [force-app/main/default/genAiPromptTemplates/IDP_Supplier_Quote_Judge.genAiPromptTemplate-meta.xml](../../force-app/main/default/genAiPromptTemplates/IDP_Supplier_Quote_Judge.genAiPromptTemplate-meta.xml) |
| LLM (判定) | Claude 4.6 Sonnet (Bedrock経由) | Einstein組込モデル | `sfdc_ai__DefaultBedrockAnthropicClaude46Sonnet` |
| Lambda | `bps-demo-idp-presign` | zip Lambda | [aws/lambda/idp-presign/](../../aws/lambda/idp-presign/) |
| Lambda | `bps-demo-idp-extract-dispatcher` | zip Lambda | [aws/lambda/idp-extract-dispatcher/](../../aws/lambda/idp-extract-dispatcher/) |
| Lambda (抽出) | `bps-demo-idp-extract` | Container Lambda (ECR) | [aws/lambda/idp-extract/](../../aws/lambda/idp-extract/) |
| LLM (抽出) | Claude Sonnet 4.6 | Anthropic直接 | `claude-sonnet-4-6` |
| Storage | S3 `bps-demo-proposals-938145531465` | prefix `idp-supplier-quote/` | 既存バケット流用 |
| API Gateway | `vdydb45kz5` 既存API | ルート `/idp/presign`, `/idp/extract` 追加 | prod stage |
| Schema | `RFQ_Quote__c` 拡張 | 37カスタムフィールド + GVS | 下記 §3 参照 |
| テストデータ | 5種サンプルPDF | | [test-data/idp-supplier-quotes/](../../test-data/idp-supplier-quotes/) |

### 2.3 LLM構成: 2段階

| Stage | 役割 | 実行場所 | モデル |
|---|---|---|---|
| Stage 1 抽出 | PDFから構造化JSON抽出 | AWS Lambda (idp-extract) | Claude Sonnet 4.6 (Anthropic直接、tool_use) |
| Stage 2 判定 | 担当者値 vs IDP値 の相違分類 | Salesforce Prompt Template | Claude 4.5 Sonnet (Bedrock経由) ※ UIで4.6に上げ済 |

判定を**Salesforce Prompt Template**で実装した理由:
- Einstein Platformによるガバナンス(プロンプト管理・Trust Layer・監査)
- テキスト比較のみでマルチモーダル不要
- Prompt Builder UIでプロンプトチューニングが宣言的

---

## 3. データモデル

### 3.1 対象オブジェクト: 既存 `RFQ_Quote__c`(購買見積回答) を拡張

新規オブジェクトは作らず、既存オブジェクトに37フィールド追加。

### 3.2 既存フィールド(担当者入力対象)

| API名 | ラベル | 型 | IDP抽出対象 |
|---|---|---|---|
| `Supplier__c` | サプライヤー | Lookup(Account) | ○ |
| `Unit_Price__c` | 単価 | Currency | ○ |
| `Lead_Time_Days__c` | 納期日数 | Number | ○ |
| `MOQ__c` | 最小発注数量 | Number | ○ |
| `Manufacturing_Site__c` | 製造拠点 | Lookup(Manufacturing_Site__c) | ○ |
| `Valid_Until__c` | 有効期限 | Date | ○ |
| `Response_Date__c` | 回答日 | Date | ○ |

### 3.3 追加フィールド(28 = 影フィールド群)

各抽出対象7項目につき4フィールドのセット:

| 命名 | 型 | 用途 |
|---|---|---|
| `AI_{項目}__c` (or `AI_Supplier_Text__c`) | 対応型、Supplierのみ Text(255) | IDP抽出値 |
| `AI_{項目}_Confidence__c` | Percent(3,0) | 信頼度(LLM自己申告) |
| `{項目}_Discrepancy_Level__c` | Picklist (GVS `IDP_Discrepancy_Level`) | 相違レベル |
| `{項目}_Discrepancy_Reason__c` | Text(255) | 判定根拠(LLM生成) |

※ サプライヤー/製造拠点はLookupだがIDP側は生テキスト(`AI_Supplier_Text__c` / `AI_Manufacturing_Site__c`)。判定時はLookup名(`Supplier__r.Name`)と比較。

### 3.4 追加フィールド(9 = IDP管理)

| API名 | 型 | 用途 |
|---|---|---|
| `IDP_Document_URL__c` | URL(255) | S3アップロード先 URL |
| `IDP_Review_Status__c` | Picklist(4値) | 業務ステータス(§4) |
| `IDP_Extracted_At__c` | DateTime | IDP抽出完了日時 |
| `IDP_Judged_At__c` | DateTime | 相違判定完了日時 |
| `IDP_Confirmed_At__c` | DateTime | 担当者確認完了日時 |
| `IDP_Overall_Discrepancy_Level__c` | Picklist(GVS) | 全項目の最悪相違レベル |
| `IDP_Judgment_Summary__c` | Long Text(2000) | 判定全体サマリ(LLM生成) |
| `IDP_Review_Note__c` | Long Text(2000) | 担当者の確認メモ(自由入力) |
| `IDP_Error_Message__c` | Text(255) | エラー詳細(空=正常) |

### 3.5 グローバル値セット: `IDP_Discrepancy_Level`

| 値 | 意味 | 表示色 |
|---|---|---|
| 未判定 | 判定未実行 | グレー |
| 一致 | 完全一致、または数値として同値 | 緑 |
| 表記差 | 法人格表記ゆれ等 | 青 |
| 読み取り差 | OCR誤認疑い | 黄 |
| 単位換算差 | 税込税抜・通貨・単位等 | 橙 |
| 致命差 | 桁違い・年違い・項目取り違え等 | 赤 |

### 3.6 権限セット

`BOM_Full_Access` 権限セットに37追加フィールドの参照+編集権限を付与済。

---

## 4. 業務ステータス設計

### 4.1 `IDP_Review_Status__c`(4値)

**業務的な状態のみ**を表現(処理状態や一時状態は含めない):

| 値 | 意味 | セット元 |
|---|---|---|
| `担当者入力完了` | 初期状態 or リセット後 | 手動(保存時) / clearIdpResult |
| `AI判定待ち` | IDP抽出完了、相違判定未実行 | Lambda(idp-extract) |
| `担当者確認中` | 判定完了、担当者の最終確認待ち | Apex startJudgment |
| `担当者確認済` | 担当者による最終確認完了(終局状態) | Apex markAsConfirmed |

### 4.2 処理状態(派生 or ローカル)

業務ステータスに含めず、以下の方法で表現:

| 状態 | 検出方法 |
|---|---|
| IDP抽出中 | `IDP_Document_URL__c` あり かつ `IDP_Extracted_At__c` null (UI: スピナー + 進捗バー) |
| 判定中 | LWC内ローカル状態 `isBusy=true`(判定ボタン押下後 Prompt Template応答まで) |
| エラー | `IDP_Error_Message__c` がnull以外(UI: 赤バナー表示、ステータスは変更しない) |

---

## 5. 業務フロー

```
[担当者入力完了] 初期状態
    │
    │ ① PDFをLWCにD&Dでアップロード
    ▼
[Lambda: S3アップ → idp-extract 起動]
    │  (派生状態: IDP抽出中、UIはスピナー)
    │
    │ ② Lambda: Claude抽出 → SF REST で AI_* 影フィールドに書き戻し
    │    + IDP_Extracted_At__c = now
    │    + status = "AI判定待ち"
    ▼
[AI判定待ち]
    │ UI: 比較テーブル表示(判定列は"未判定")
    │     [相違判定を実行] ボタン表示
    │
    │ ③ 担当者が必要に応じて入力値修正 → [保存] → [相違判定を実行]
    ▼
[LWC: form.submit() → Prompt Template呼び出し]
    │  (派生状態: 判定中、UIはローカル busy)
    │
    │ ④ Prompt Template: 5段階分類 + overall_level + summary
    │    Apex: 結果を各フィールドにUPDATE
    │    + status = "担当者確認中"
    ▼
[担当者確認中]
    │ UI: 色分け比較テーブル + 判定サマリ + メモ入力欄
    │     [確認完了] / [やり直す] ボタン表示
    │
    │ ⑤ 担当者が入力値を再修正(必要なら) + メモ記入 → [確認完了]
    ▼
[LWC: form.submit() → markAsConfirmed]
    │
    │ ⑥ 確認完了
    ▼
[担当者確認済] 終局状態
    UI: 読取専用表示 + メモ表示 + [やり直す] のみ
```

**設計方針**:
- **判定後の入力値修正でも再判定しない**: AIが誤っている可能性があり、担当者判断を優先
- **致命差が残ったまま確認済にできる**: 担当者がメモで根拠を残せば監査上問題なし
- **エラー時もステータスは変えない**: エラーメッセージだけ記録、UI上バナー表示

---

## 6. UI仕様

### 6.1 LWC `idpQuoteFileUploader`(ファイルアップロード専用)

コンパクトな見た目(既存 proposalUploader と同等の UX)。

| 状態 | 表示内容 |
|---|---|
| 通常 | ドロップゾーン(PDF/PNG/JPG) + ファイル選択ボタン |
| ファイル選択済 | ファイル情報 + [アップロード開始] |
| IDP抽出中 | スピナー + 進捗バー + "IDPが項目を抽出中..." |
| 抽出完了 | 緑の完了バナー + ドロップゾーン(再アップ可) |
| エラー | 赤いエラーバナー(IDP_Error_Message__c表示) |

**ステータスバッジは表示しない**(状態はUIのメッセージで表現)。
**ポーリング**: 抽出中に3秒間隔で`getIdpStatus` wire を refreshApex。`IDP_Extracted_At__c` が入ったら停止。

### 6.2 LWC `idpQuoteDualEntry`(担当者入力+比較+判定)

4列レイアウトのメインUI。標準Detail Panelの代わりに担当者入力を担う。

| 列 | 内容 |
|---|---|
| 項目 | フィールドラベル(サプライヤー/単価/等) |
| 担当者 | `lightning-input-field` で直接編集可(Lookup/Currency/Number/Date 型対応) |
| IDP抽出 (信頼度) | 読取専用表示、信頼度 `(99%)` 併記 |
| AI判定結果 | 相違レベルバッジ + reason テキスト |

**ヘッダー**: 「全体判定」バッジ のみ(ステータスバッジは表示しない)
**右上アクション**: [再読み込み]アイコンボタン(`refreshApex`)
**下部ボタン**: ステータスに応じて [保存] / [相違判定を実行] / [確認完了] / [やり直す] を出し分け
**編集可タイミング**: 担当者入力完了 と 担当者確認中 のみ(他状態はLightning Input Field を disabled)

### 6.3 標準Detail Panel の扱い

FlexiPage に残置。IDP対象外の項目(Notes__c, Score__c, Status__c 等)は標準フォームで編集。

### 6.4 FlexiPage `RFQ_Quote_Record_Page`

`Highlights Panel` + `Detail Panel` + `Related List Container` の最小構成。**LWCの配置はユーザがLightning App Builderで手動調整**する前提。

---

## 7. Prompt Template仕様

### 7.1 `IDP_Supplier_Quote_Judge`

- **Type**: einstein_gpt__flex
- **Input**: `analysisData`(primitive://String、JSON形式)
- **Output**: JSON(judgments × 7項目 + overall_level + summary)
- **Primary Model**: `sfdc_ai__DefaultBedrockAnthropicClaude46Sonnet`

### 7.2 入力JSON構造(Apex→Prompt Template)

```json
{
  "fields": [
    {"field": "supplier_name", "label": "サプライヤー名", "human": "東亜電子工業", "ai": "東亜電子工業"},
    {"field": "unit_price", "label": "単価", "human": 4800, "ai": 4800},
    ...
  ]
}
```

### 7.3 出力JSON構造(Prompt Template→Apex)

```json
{
  "judgments": [
    {"field": "supplier_name", "level": "一致", "reason": "担当者・IDP双方とも「東亜電子工業」で完全一致。"},
    ...
  ],
  "overall_level": "一致",
  "summary": "全7項目において担当者とIDPの抽出値は完全に一致しており、相違は認められない..."
}
```

### 7.4 用語統一

プロンプト本文で「担当者」「IDP」の用語を統一使用するよう明示指示(「人間」「AI」は使用禁止)。判定結果のreasonとsummaryが担当者向けに自然な日本語になる。

### 7.5 ⚠️ メタデータデプロイ後の再Activate

プロンプト内容を更新したときは **Prompt Builder UIで手動Activate必要**(Salesforceの既知仕様、自動反映されない)。

---

## 8. 実装成果物サマリ

| # | 成果物 | パス |
|---|---|---|
| 1 | スキーマ(37フィールド) | [force-app/main/default/objects/RFQ_Quote__c/fields/](../../force-app/main/default/objects/RFQ_Quote__c/fields/) |
| 2 | Global Value Set | [force-app/main/default/globalValueSets/IDP_Discrepancy_Level.globalValueSet-meta.xml](../../force-app/main/default/globalValueSets/IDP_Discrepancy_Level.globalValueSet-meta.xml) |
| 3 | 権限セット追記 | [force-app/main/default/permissionsets/BOM_Full_Access.permissionset-meta.xml](../../force-app/main/default/permissionsets/BOM_Full_Access.permissionset-meta.xml) |
| 4 | Apex(7メソッド + テスト 6/6 pass) | [force-app/main/default/classes/IdpSupplierQuoteController.cls](../../force-app/main/default/classes/IdpSupplierQuoteController.cls) |
| 5 | Prompt Template | [force-app/main/default/genAiPromptTemplates/IDP_Supplier_Quote_Judge.genAiPromptTemplate-meta.xml](../../force-app/main/default/genAiPromptTemplates/IDP_Supplier_Quote_Judge.genAiPromptTemplate-meta.xml) |
| 6 | LWC×2 | [force-app/main/default/lwc/idpQuoteFileUploader/](../../force-app/main/default/lwc/idpQuoteFileUploader/), [force-app/main/default/lwc/idpQuoteDualEntry/](../../force-app/main/default/lwc/idpQuoteDualEntry/) |
| 7 | FlexiPage | [force-app/main/default/flexipages/RFQ_Quote_Record_Page.flexipage-meta.xml](../../force-app/main/default/flexipages/RFQ_Quote_Record_Page.flexipage-meta.xml) |
| 8 | Lambda×3 + Dockerfile | [aws/lambda/idp-presign/](../../aws/lambda/idp-presign/), [aws/lambda/idp-extract-dispatcher/](../../aws/lambda/idp-extract-dispatcher/), [aws/lambda/idp-extract/](../../aws/lambda/idp-extract/) |
| 9 | AWS IAM Role (新規1本) | `bps-demo-idp-extract-dispatcher-role` |
| 10 | AWS ECR Repo | `bps-demo/idp-extract` |
| 11 | API Gateway ルート | `/idp/presign`, `/idp/extract` |
| 12 | サンプルPDF 5種 | [test-data/idp-supplier-quotes/](../../test-data/idp-supplier-quotes/) |

---

## 9. 実装で得た知見

### 9.1 設計上の決定と理由

| 論点 | 決定 | 理由 |
|---|---|---|
| Lambda本数 | presign + dispatcher + extract の3本 | dispatcherでAPI Gateway 29秒タイムアウトを回避。既存proposalUploader踏襲 |
| 判定をPrompt Templateに | Stage 2 だけ Prompt Template | Einstein Platformのガバナンスと、テキスト比較のみでマルチモーダル不要のため |
| ステータス設計 | 業務4値 + 処理状態は派生 | UIのステータス表示をシンプルに保つ。担当者には技術的状態は見せない |
| LWC 2分割 | Uploader と DualEntry で分離 | 責務分離。Uploaderは挙動がproposalUploaderと揃う |
| 信頼度表示 | 画面に残置 | Mulesoft IDP自体も信頼度を返すため、UI上の情報価値はある(監視・フィルタ用途) |
| 編集可タイミング | 担当者入力完了 と 担当者確認中 のみ | 入力の独立性(ダブルチェック原則)を維持 |

### 9.2 Salesforce技術的知見(再利用可能)

**これらは `docs/reference/known-issues.md` にも転載済**

- **`@wire` + `cacheable=false` は動作しない**: `@wire` は `cacheable=true` 必須。Apex wireで `cacheable=false` を指定すると wire callback が発火しない(imperative callは可)。今回`getFullRecord`と`getIdpStatus`で発覚、cacheable=trueで解決。
- **複数LWC間の wire cache 共有**: 同じApex method + 同じ引数で wire すると、異なるLWCでもキャッシュが共有される。1つのLWCで `refreshApex` すると全LWCに波及。今回これで2LWC間のステータス同期を実現。
- **Prompt Template content更新後は手動Activate必要**: メタデータデプロイではActivateが自動反映されない。UIで明示Activateしないと `Runtime version information was not found` エラー。既にknown-issues.md記載あり。
- **LWC の業務ステータスと処理状態の分離**: 業務ステータス(Picklist)と処理状態(DateTime/Error field等から派生)を分離すると、ユーザにとって理解しやすくメンテも容易。

### 9.3 LLM関連の知見

- **信頼度はLLMの自己申告、キャリブレーションされた確率ではない**: Claudeは読み取りが明確な値には99%を付けがち。絶対値で判断せず、低信頼度(<70%等)の検知用に使う。
- **LLMは単位換算を自発的に行う**: 「45 business days」→ LLMが「営業日」と解釈し45×7/5=63カレンダー日を返す、等。担当者入力値と比較時に「致命差」扱いされ得るので、入力フォーマット設計で注意。
- **判定用Prompt Templateには生値のみ渡る**: 単位やコンテキストは Stage 1 抽出時に正規化しておかないと、Stage 2 判定では区別不能。将来改善候補: 抽出JSONに `unit` フィールドを持たせる。
- **Prompt Templateでの用語統一指示は効く**: 「必ず担当者/IDPの語を使うこと」と冒頭で明示すると、reasonもsummaryもその通りに生成される。

### 9.4 業務シナリオの面白い示唆

- 全項目一致のケースも価値がある: ダブルチェックで「問題なかった」ことの監査証跡になる
- 致命差が残ったまま確認済にできる仕様は、AIの誤判定に対する担当者のオーバーライドを許容するため必要

---

## 10. 未実装・将来拡張

### 10.1 今回未実装(元設計の Phase 5-8)

| Phase | 内容 | ステータス |
|---|---|---|
| Phase 5 | デモ用RFQ 5件 + サンプルPDF 5種 | サンプルPDF完了、RFQは1件のみ(QT-0032) |
| Phase 6 | E2Eテスト全通し | 部分(QT-0032で全フロー検証済) |
| Phase 7 | 監査レポート 4-5本 | **未着手** |
| Phase 8 | `IDP_Schema__mdt` / `IDP_Field_Mapping__mdt` (Custom Metadata化) | **未着手** |

### 10.2 改善アイデア

- 抽出LLMから単位情報(税抜/税込、カレンダー日/営業日、JPY/USD等)も JSON化 → 判定LLMに単位コンテキストを渡せば「単位換算差」の検出精度が上がる
- サプライヤーAccount解決の fuzzy match: AI抽出の生テキストから自動で一番近いAccountを提案
- 確認済みレコードの差分レポート: 致命差が残ったまま確認済になった件の一覧
- 信頼度閾値によるUI装飾: 70%未満は黄色ハイライト

---

## 11. テスト用レコード

デモ・動作確認用:
- **Id**: `a2xIe000000Go5QIAS` (Name: QT-0032)
- **RFQ**: `a2yIe000000LkoZIAS` (IDP動作確認テスト)
- **Supplier**: 東亜電子工業 (RecordType: サプライヤー)
- **Manufacturing_Site**: 東亜電子 本社工場
- baseline担当者入力値は [test-data/idp-supplier-quotes/README.md](../../test-data/idp-supplier-quotes/README.md) 参照
