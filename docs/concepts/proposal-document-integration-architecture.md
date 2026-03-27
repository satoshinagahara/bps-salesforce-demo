# 提案書コンテキスト統合 — アーキテクチャ構想

作成日: 2026-03-26
ステータス: 構想段階（壁打ち中）

## 根本的な問い: サマリカードのコンテキスト源はどこにあるべきか

### SFAの入力負荷問題

商談類似度分析（Phase A完了）は、商談メタデータ＋活動＋面談記録からサマリカードを生成している。
しかし、サマリカードの品質を上げるためにSalesforceの入力充実度を求めることは、**営業担当者への追加作業負担**を意味する。

現実の多くの企業では:
- Salesforceの入力は**パイプライン管理・フォーキャスト**に特化させたい
- 営業活動の実態・提案ロジック・顧客課題認識は**提案書に凝縮**されている
- Salesforceの活動記録は「電話した」「訪問した」程度で、中身は薄いケースが多い

類似商談による示唆というユーザーメリットはあるが、それが「SFAの詳細入力」を前提とするなら、**メリットとコストが相殺（プラマイゼロ）**になる。

### 前提の転換

```
従来の設計:
  Salesforce（主）→ 活動・面談・Description → サマリカード
  提案書（補助）→ 追加コンテキスト

あるべき姿:
  提案書（主）→ 提案ロジック・課題理解・価値提案 → サマリカード
  Salesforce（構造）→ 顧客・金額・フェーズ・商品 → 検索軸・フィルタ
```

**提案書は「サマリカードの補助入力」ではなく、主たるコンテキスト源。**
Salesforceのデータは構造的なメタデータ（顧客・金額・フェーズ・商品）を提供する役割に留める。

これにより「営業が本来やっている仕事（提案書作成）の副産物としてナレッジが蓄積される」モデルとなり、**ユーザーへの追加入力負荷がゼロ**になる。

---

## 理想のUX

```
営業担当者の操作: 商談ページのLWCに提案書PPTXをドラッグ&ドロップ
                   ↓
            [1] ファイル転送
                   外部ストレージ（S3/SharePoint等）の適切なフォルダにアップロード
                   ↓
            [2] URL返却
                   Salesforceにファイル参照URLが戻る
                   ↓
            [3] テキスト抽出（同期 or 非同期）
                   マルチモーダルLLMがスライド画像を解釈
                   → 意味のあるテキスト（提案の趣旨・課題認識・価値提案）を生成
                   ↓
            [4] 紐付け
                   商談に URL＋抽出テキスト がセットで保存
                   ↓
            [5] バッチ処理
                   OpportunitySummaryBatch が提案コンテキストを含めてサマリカード生成
```

**ポイント: 営業担当者の動作は「ファイルを投げ込む」だけ。** SFAの追加入力は一切不要。

---

## 技術的実現性の評価

| ステップ | 実現性 | 備考 |
|---|---|---|
| [1] LWCからファイルアップロード | ○ | LWCのfile input → Named Credential経由で外部APIコール。Apexが中継 |
| [2] URL返却・保存 | ◎ | 単純なDML |
| [3] マルチモーダルLLM解析 | ○ | **ここだけSalesforce外の処理が必須**。Apex callout → 外部API（Lambda等）→ LLM |
| [4] テキスト紐付け | ◎ | カスタムオブジェクト or LongTextArea |
| [5] バッチ統合 | ◎ | 既存のOpportunitySummaryBatchの入力ソース追加 |

**ボトルネックは[3]のみ。** マルチモーダルLLM処理をどこでホストするかが唯一の技術的課題。

### PPTXからのテキスト抽出 — 技術の現在地

| アプローチ | テキスト抽出 | 図表・チャート | 文脈理解 | 実用度 |
|---|---|---|---|---|
| 構造パース（python-pptx / Tika） | ○ テキストボックスは取れる | × 断片の羅列 | × 文脈消失 | △ |
| OCR（スライド画像化→文字認識） | ○ 画面上の全テキスト | △ 文字は拾えるが関係性不明 | × | △ |
| マルチモーダルLLM（スライド画像→Claude Vision等） | ◎ | ○ 傾向・大小関係を解釈 | ◎ レイアウト・矢印・流れを理解 | **◎** |

マルチモーダルLLMによる「スライド画像→意味のあるテキスト再構成」は**実用レベルに達している**。
テキスト中心スライド・表・フローチャートは高精度。複雑なアーキテクチャ図は細部でミスの可能性あり。

---

## 実運用の前提条件

理想のUXを実現するには、技術的実現性だけでなく以下の前提が揃っている必要がある。

### 認証・認可

| 前提 | 理由 | 備考 |
|---|---|---|
| **SSO（シングルサインオン）** | Salesforce↔外部ストレージ間でユーザー認証を統一する必要がある。LWCからファイルをアップロードする際、ストレージ側の権限をSalesforceユーザーに紐づけて検証する必要がある | IdP（Entra ID / Okta等）によるSAML/OIDC統合が前提 |
| **ストレージ側の権限連動** | アップロード先のフォルダ/バケットの読み書き権限・共有設定がSalesforceユーザーの組織ロールと連動する必要がある | SharePointの場合、M365のセキュリティグループとSalesforceのロール階層のマッピングが必要 |
| **OAuth 2.0フロー** | LWC→Apex→外部ストレージAPIの認証チェーンにおいて、Named Credential + OAuth 2.0（Authorization Code / Client Credentials）の構成が必要 | Per-User Named Credential（ユーザーごとの認可）が理想だが、設定・運用が複雑 |

### セキュリティ・コンプライアンス

| 前提 | 理由 |
|---|---|
| **データ居住地** | LLM APIにファイルを送信する場合、提案書の内容が外部サービスに渡る。顧客固有の価格・条件・技術情報が含まれるため、データ処理場所のポリシー確認が必要 |
| **閲覧制限の引き継ぎ** | 提案書には機密情報が含まれる場合がある。抽出テキストやサマリカードにもストレージ側と同等のアクセス制御が必要 |
| **監査証跡** | 誰がいつどのファイルをアップロードし、テキスト抽出が行われたかのログ |

### 運用

| 前提 | 理由 |
|---|---|
| **ファイル命名・格納ルール** | 「どの商談の提案書か」を自動判定するためには、フォルダ構造や命名規則が統一されているか、LWCからの紐付けで明示的に関連付ける必要がある |
| **バージョン管理** | 提案書は複数回改訂される。最新版のみ使うか、差分にも価値があるか |
| **LLM処理コストの予算化** | スライド枚数×商談数のAPI費用を運用コストとして組み込む必要がある |

---

## アーキテクチャパターン比較

### パターン1: Salesforce Files Connect

```
SharePoint / OneDrive / Google Drive
  ↓ Files Connect（標準機能）
Salesforce Files（外部参照）
  ↓ ContentDocument API
Apex でテキスト抽出 → サマリカード生成
```

| 観点 | 評価 |
|---|---|
| 導入容易性 | ◎ 標準機能。Named Credential + Auth Provider設定のみ |
| 対応ストレージ | △ SharePoint / OneDrive / Google Drive / Box（要アダプタ） |
| ファイル操作 | △ 参照・リンクのみ。Salesforceにコピーはされない |
| テキスト抽出 | × Salesforce側にPDF/PPTパース機能なし。Apexでバイナリ処理は非現実的 |
| リアルタイム性 | ○ ユーザー操作時にオンデマンド取得 |
| 制約 | Files Connectは「ファイルの参照UI」であり、コンテンツのプログラマティック処理には不向き |

**結論: ファイルの「存在確認・リンク」はできるが、中身のテキスト抽出には別の仕組みが必要。**

### パターン2: MuleSoft + 文書解析サービス

```
SharePoint / OneDrive / Box
  ↓ MuleSoft Connector
MuleSoft（オーケストレーション）
  ↓ 文書解析サービス呼び出し
  │  ├ Azure AI Document Intelligence（旧 Form Recognizer）
  │  ├ Amazon Textract
  │  ├ Google Document AI
  │  └ Unstructured.io 等のOSS
  ↓ 抽出テキスト
Salesforce（Platform Event or REST）
  → サマリカード生成パイプラインに統合
```

| 観点 | 評価 |
|---|---|
| 導入容易性 | × MuleSoftライセンス＋文書解析サービス契約が必要 |
| 対応ストレージ | ◎ MuleSoftコネクタで主要ストレージ全対応 |
| ファイル形式 | ◎ PDF / PPTX / DOCX / 画像 — 文書解析サービス依存 |
| テキスト抽出精度 | ◎ 専門サービスなので高精度（図表含む） |
| リアルタイム性 | ○ イベントドリブンまたはスケジュール |
| スケーラビリティ | ◎ MuleSoft側でスケール |
| 制約 | コスト大。エンタープライズ向け |

**結論: 最も柔軟だがコスト・導入ハードルが高い。大企業の本番実装向け。**

### パターン3: Data Cloud Ingestion + Unstructured Data

```
SharePoint / OneDrive / Box
  ↓ Data Cloud Connector（Zero Copy or Ingestion）
Data Cloud DLO
  ↓ マッピング
Data Cloud DMO（ドキュメントメタデータ）
  ↓ Unstructured Data Pipeline（Data Cloud機能）
チャンク化 → ベクトル埋め込み → Search Index
  ↓ Retriever
サマリカード生成時にRAG検索で提案書コンテキストを注入
```

| 観点 | 評価 |
|---|---|
| 導入容易性 | △ Data Cloudライセンス必要（本環境にはあり）。Unstructuredパイプラインは比較的新しい機能 |
| 対応ストレージ | ○ S3 / GCS / Azure Blob経由。SharePoint直接コネクタは限定的 |
| ファイル形式 | ○ PDF対応。PPTXは要検証（2026年時点） |
| テキスト抽出精度 | △ Data Cloud内蔵パーサーの精度はサービス専門ツールに劣る |
| RAG統合 | ◎ Retriever + Data Graph でサマリカード生成パイプラインに直接統合可能 |
| スケーラビリティ | ◎ Data Cloud基盤 |
| 制約 | ファイルをS3等に一旦集約する必要がある場合が多い。SharePoint → S3の橋渡しが別途必要 |

**結論: Data Cloud中心のアーキテクチャとしては自然だが、外部ストレージ→Data Cloudの経路構築が課題。**

### パターン4: 外部パイプライン（Lambda/Functions） + Salesforce API

```
SharePoint / OneDrive / Box
  ↓ Webhook / Graph API / Box Events
AWS Lambda or Cloud Functions（イベントドリブン）
  ↓ 文書解析（Textract / Document AI / LLM直接）
  ↓ テキスト抽出 + 要約
Salesforce REST API
  → Opportunity_Summary__c の補助フィールドに格納
  or
  → 専用オブジェクト Proposal_Context__c に格納
```

| 観点 | 評価 |
|---|---|
| 導入容易性 | ○ サーバレス関数＋クラウドサービスの組み合わせ。Salesforce側の変更は最小限 |
| 対応ストレージ | ◎ 各ストレージのAPIを直接利用 |
| ファイル形式 | ◎ 外部サービス依存で自由度高い。LLM直接投入（Claude Vision等）も選択肢 |
| テキスト抽出精度 | ◎ サービス選択の自由度が高い |
| リアルタイム性 | ◎ ファイル更新イベントでトリガー可能 |
| スケーラビリティ | ◎ サーバレスでスケール |
| 制約 | Salesforce外の基盤構築・運用が必要。セキュリティ設計（認証・暗号化）も自前 |

**結論: 柔軟性は最高だが、Salesforce外のインフラ構築・運用コストがかかる。**

### パターン5: LLM Vision直接投入（PPTXをスライド画像化→マルチモーダルLLM）

```
SharePoint / OneDrive / Box
  ↓ API取得
PPTXファイル
  ↓ スライド→画像変換（LibreOffice / pdf2image等）
Claude Vision / GPT-4V
  ↓ スライドごとの要約テキスト
  ↓ 全スライド統合要約
サマリカード生成パイプラインに統合
```

| 観点 | 評価 |
|---|---|
| 導入容易性 | ○ LLM API呼び出しのみ。文書解析サービス不要 |
| PPT図表対応 | ◎ マルチモーダルLLMがチャート・図・レイアウトを直接解釈 |
| テキスト抽出精度 | ○ テキスト中心のスライドは高精度。複雑な図表は解釈にブレあり |
| コスト | △ スライド枚数×画像トークンのAPI費用 |
| 制約 | ファイル取得経路は別途必要。バッチ処理時のAPI費用に注意 |

**結論: PPTの図表問題を解決する有力な選択肢。ファイル取得経路と組み合わせて使う。**

### 理想UXとの対応

理想UX（LWCからファイル投入→自動でナレッジ蓄積）を実現するには、**パターン4 or 5の外部処理基盤 + パターン1 or 3のストレージ連携**を組み合わせる必要がある。単一パターンでは完結しない。

想定される組み合わせ:

```
[理想構成]
LWC（ファイル投入UI）
  ↓ Apex callout
外部API Gateway（Lambda / Cloud Functions）
  ├→ ストレージAPI（SharePoint Graph API / S3 / Box API）へアップロード
  ├→ スライド画像化 + マルチモーダルLLM（パターン5）
  └→ Salesforce REST API で結果を返却
       → Proposal_Context__c に URL + 抽出テキスト を保存
            ↓
       OpportunitySummaryBatch（既存バッチ）が提案コンテキストを含めて生成
```

---

## パターン組み合わせマトリクス

### ファイル取得経路

| 経路 | SharePoint | OneDrive | Box | Google Drive |
|---|---|---|---|---|
| Files Connect | ○ | ○ | △ | ○ |
| MuleSoft Connector | ◎ | ◎ | ◎ | ◎ |
| 各ストレージAPI直接 | ◎（Graph API） | ◎（Graph API） | ◎（Box API） | ◎（Drive API） |
| S3中継 | △（要橋渡し） | △（要橋渡し） | △（要橋渡し） | △（要橋渡し） |

### テキスト抽出方式

| 方式 | PDF | PPTX | DOCX | 図表解釈 | コスト |
|---|---|---|---|---|---|
| Data Cloud内蔵パーサー | ○ | △ | ○ | × | 低 |
| Azure AI Document Intelligence | ◎ | ◎ | ◎ | ○ | 中 |
| LLM Vision（Claude/GPT-4V） | ◎ | ◎（画像化経由） | ◎ | ◎ | 中〜高 |
| Apache Tika等OSS | ○ | ○ | ◎ | × | 低 |

### Salesforce統合方式

| 方式 | 用途 |
|---|---|
| サマリカード直接拡張 | Opportunity_Summary__c に `proposal_context__c`（LongTextArea）を追加。サマリ生成時の入力ソースに含める |
| 専用オブジェクト | Proposal_Context__c（MD→Opportunity）に提案書ごとのテキスト・要約を格納。サマリ生成時にSOQLで取得 |
| Data Cloud RAG | Data Cloud DMOに格納→Retriever経由で検索。サマリ生成Prompt Templateにground truthとして注入 |

---

## デモ環境での選択肢

本環境はデモ目的であり、外部ストレージの実環境は存在しない。以下の選択肢がある：

### 案A: 「提案書テキスト」を直接投入する簡易パターン

```
（手動 or スクリプトで提案書テキストを準備）
  ↓
Proposal_Context__c に格納
  ↓
OpportunitySummaryBatch 拡張 — 生成時に提案書コンテキストも参照
```

- **メリット**: 外部連携なしで「提案書がメインコンテキストの場合のサマリカード品質」を検証可能
- **デメリット**: 実際のアーキテクチャパターンのデモにはならない
- **目的**: 前提転換（提案書メイン）の仮説検証

### 案B: S3 + Data Cloudパイプライン（既存RAG基盤の拡張）

```
S3にサンプル提案書PDF配置
  ↓ Data Cloud Connector（既存のイベントアンケートと同じ経路）
Data Cloud DLO → DMO
  ↓ Search Index + Retriever
サマリカード生成時にRAG検索
```

- **メリット**: 既存のData Cloud RAG基盤（イベントアンケート）を応用可能。アーキテクチャデモとしても成立
- **デメリット**: PDF限定（PPTXは未対応の可能性）。Data Cloud Unstructured Pipelineの検証が必要
- **目的**: Data Cloud中心のドキュメント統合アーキテクチャの実証

### 案C: LLM Vision デモ（PPTスライド→画像→要約）

```
サンプルPPTXをスライド画像化（ローカル前処理）
  ↓ Claude Vision API
スライドごとのテキスト抽出・要約
  ↓ Salesforce API
Proposal_Context__c に格納
```

- **メリット**: PPT図表問題を解決するデモとして強い。マルチモーダルLLMの価値を示せる
- **デメリット**: ファイル取得経路は含まない。前処理がSalesforce外
- **目的**: 文書解析技術のPoC

---

## PoC実施結果（2026-03-27）

### 構成

案Cの「LLM Vision デモ」をAWS Lambda上で実装し、動作検証を完了。

```
S3（bps-demo-proposals-938145531465）
  └ proposals/bps-energy-platform-proposal.pptx
        ↓
Lambda: bps-demo-pptx-extractor（Docker image、x86_64）
  ├ LibreOffice 26.2（PPTX → PDF変換）
  ├ poppler pdftoppm（PDF → PNG画像、200dpi）
  └ Claude Vision API（claude-sonnet-4-20250514）
        ↓
  スライドごとのテキスト抽出 + 全体統合要約
```

### テスト素材

python-pptxで生成した7枚のサンプル提案書（関東広域エネルギー公社向けエネルギー管理プラットフォーム導入提案）。
図形内テキスト散在、棒グラフ（Chartオブジェクト）、折れ線グラフ、ガントチャート風テーブル、フローチャート等を含む。

### 結果

| スライド | 内容 | 抽出精度 |
|---|---|---|
| 1. 表紙 | 提案番号、提案先、担当者 | ◎ 全項目正確 |
| 2. 顧客課題 | 4課題（図形ボックス＋影響度ラベル） | ◎ 320拠点、5人日、42%等の数値も正確 |
| 3. ソリューション全体像 | 4層アーキテクチャ図（矢印・吹き出し） | ◎ 層構造・デバイス台数・プロトコル名を正確に読み取り |
| 4. 導入効果 | 棒グラフ（Chartオブジェクト）＋数値テーブル | ◎ 削減率・金額を正確に抽出 |
| 5. スケジュール | ガントチャート風テーブル＋マイルストーン | ◎ 3フェーズ・各タスク・期間を正確に記述 |
| 6. ROI | 投資/効果テーブル＋折れ線グラフ＋損益分岐点 | ◎ 費目ごとの金額、ROI 115%、IRR 22%等を正確に抽出 |
| 7. 次のステップ | ステップフロー＋連絡先＋早期特典 | ◎ 全アクションアイテムを正確に記述 |

**統合要約**: 全スライドの内容を提案の目的→課題→ソリューション→効果→スケジュール→ROI→次のステップの論理構造で正しく再構成できた。

### 得られた知見

1. **日本語フォントは必須**: LibreOfficeのPDF変換時に日本語フォントがないと文字化けし、Claude Visionが誤読する。`google-noto-sans-cjk-jp-fonts` を追加して解決
2. **図表解釈は実用レベル**: Chartオブジェクト（棒グラフ・折れ線）、フローチャート、ガントチャートいずれも意味のある文章に変換できた
3. **数値精度が高い**: 金額・パーセンテージ・台数等の定量情報も正確に抽出
4. **処理時間**: 7スライドで約60〜90秒（LibreOffice変換＋Claude Vision API 7回＋統合要約1回）
5. **Lambda設定**: timeout 300s、memory 1024MB で十分動作。Ephemeral Storage はデフォルト512MBで問題なし

### デプロイ済みAWSリソース

| リソース | 名前 | 備考 |
|---|---|---|
| ECR | `bps-demo/pptx-extractor` | ap-northeast-1 |
| Lambda | `bps-demo-pptx-extractor` | Docker image、x86_64、300s timeout、1024MB |
| IAM Role | `bps-demo-pptx-extractor-role` | LambdaBasicExecution + S3ReadOnly + SSMReadOnly |
| S3 | `bps-demo-proposals-938145531465` | 提案書アップロード用 |
| SSM | `/bps-demo/anthropic-api-key` | Anthropic APIキー（SecureString） |

### PoC結論

**マルチモーダルLLMによるPPTXテキスト抽出は実用レベルに達している。** 提案書をサマリカードの主たるコンテキスト源とするアーキテクチャは技術的に実現可能。

---

## 次のステップ

1. **Salesforce側の受け口構築**: `Proposal_Context__c` カスタムオブジェクト（MD→Opportunity）を作成し、抽出テキスト＋ファイルURLを格納
2. **Connected App作成 + Lambda認証設定**: Lambda→Salesforce REST APIの書き戻し用OAuth。client_id/secretをSSM Parameter Storeに格納
3. **Lambda拡張**: 処理完了後にSalesforce REST APIで`Proposal_Context__c`レコードを直接作成する非同期書き戻し
4. **OpportunitySummaryBatch拡張**: サマリカード生成時に `Proposal_Context__c` のテキストを入力ソースに追加
5. **品質比較**: 提案書ありサマリカード vs なしサマリカードの品質差を定量評価
6. **LWCファイル投入UI**: 商談ページからPPTXをドラッグ&ドロップ→Lambda呼び出し→結果保存のフロー実装

### 非同期書き戻しの設計方針（2026-03-27合意）

LWCからのファイル投入は非同期処理が必須（Apexの120秒callout制限に収まらない可能性）。
Lambdaが処理完了後にSalesforce REST APIで直接書き戻すパターンAを採用。

```
LWC → Apex → Lambda（非同期キック、opportunityIdも渡す）
                ├→ PPTX → 画像 → Claude Vision → テキスト抽出
                └→ Salesforce REST API（Connected App OAuth）で Proposal_Context__c を作成
```

**LambdaがOAuth認証の2方向ハブになる構成:**
- ストレージ側（SharePoint Graph API / S3等）: ファイル保存
- Salesforce側（Connected App + Client Credentials or JWT Bearer）: 結果書き戻し

Connected Appの設定はSalesforce側で実施→client_id/secretをSSM Parameter Storeに格納。

---

## LWC改善バックログ

- [ ] アップロード済み提案書一覧からProposal_Context__cレコードへのリンク
- [ ] ファイル削除機能（S3のファイル + Salesforceレコードの両方を削除）
- [ ] ファイル差し替え（同名ファイルの上書き + テキスト再抽出）
- [ ] 「処理中」状態のレコードが画面再訪問時に表示されるようにする（キャッシュ問題の改善）

---

## 未整理の論点

1. **提案書の粒度問題**: 1商談に複数バージョンの提案書がある場合、どれを使うか？最新版のみ？差分も価値がある？
2. **機密性**: 提案書には顧客固有の価格・条件が含まれる。抽出テキストやサマリカードにもストレージ側と同等のアクセス制御が必要
3. **鮮度**: 提案書が更新されたらサマリカードも再生成すべきか？トリガー設計
4. **ファイル形式の現実**: 提案書はPPTXが多数だが、RFP回答書はDOCX/PDF、技術仕様書はPDFが多い。複数形式対応が必要
5. **テキスト量問題**: 100ページの提案書全文をサマリカード生成のコンテキストに入れるのは非現実的。事前要約 or チャンク検索が必要
6. **Salesforce入力との役割分担**: 提案書をメインコンテキストにした場合、既存の活動・面談記録はどう位置付けるか。完全に無視するか、補助的に使うか
