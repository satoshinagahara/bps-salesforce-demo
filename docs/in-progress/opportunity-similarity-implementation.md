# 商談類似度分析 Agentforce実装 作業ログ

**目的**：商談サマリカードを検索基盤として、Agentforce Topicで類似商談検索＋示唆生成を実装する
**作成日**：2026-03-24
**ステータス**：✅ PoC動作確認完了（2026-03-24）
**関連**：`docs/concepts/opportunity-similarity-design-concept.md`

---

## 実装方針

BOM_Analysis_Agent（製品・調達・品質マネジメントエージェント）に「商談類似分析」Topicを追加。
**1アクション統合パターン**（Apex内でConnectApi経由でPrompt Templateを呼び出し）を採用。

### 最終コンポーネント構成

```
Topic: 商談類似分析
  └─ Action: OpportunitySimilaritySearch（Apex Invocable — 1アクション統合）
       入力: opportunityId（現在の商談ID）
       内部処理:
         1. 商談のサマリカード取得（SOQL）
         2. 構造化フィールドで類似商談をSOQL検索（最大4件）
         3. ConnectApi経由でPrompt Template呼び出し（レポート生成）
       出力: 分析レポートテキスト（そのままユーザーに表示）
```

> **2アクション分離パターン（Apex → Prompt Template）は採用しなかった。**
> Agent LLMがAction間で大量JSONを受け渡す際、maxLength 255制限とJSONエスケープ破損により失敗する。
> 詳細: `metadata-agentforce.md` セクション 0-8、`prompt-templates.md` セクション 6-5

---

## 完了済み

### 1. Opportunity_Summary__c カスタムオブジェクト（✅）

構造化フィールド9個 + 自由記述フィールド8個 + Lookup 1個 = 18フィールド。
BOM_Full_Access権限セットにオブジェクト権限・FLS・タブ可視性を追加済み。

> **FLS注意**: Lookup（Opportunity__c）もFLS設定が必要。required=falseのLookupはFLS未設定だとSOQL/DMLで見えない。

### 2. テストデータ投入（✅）

14件の商談サマリカードを投入済み。

| deal_type | 件数 |
|---|---|
| 設備導入 | 5件（A-1, A-2, A-3, A-4, C-2） |
| ソフトウェア・クラウド | 4件（B-1, B-2, B-3, B-4） |
| Design Win・OEM | 2件（C-1, C-3） |
| 保守・サービス | 3件（D-1, D-2, D-3） |

### 3. Apex Invocable Action: OpportunitySimilaritySearch（✅）

- クラス: `OpportunitySimilaritySearch.cls`
- 入力: `opportunityId`（商談ID）
- 検索戦略（合計最大4件に絞る）:
  1. `deal_type`一致で同クラスタ検索（最大2件）
  2. `sales_motion`一致でクラスタ横断検索（最大1件）
  3. `urgency_driver`一致で動機が同じ商談を検索（最大1件）
  4. `Sales_Process_Pattern__c != null` でSparseデータを除外
- ConnectApi経由でPrompt Template `OpportunitySimilarityInsights` を呼び出し
- 出力: 分析レポートテキスト

**パフォーマンス最適化**:
- JSONのフィールドをコンパクトに（キー名短縮、不要フィールド除外）
- 類似商談数を最大4件に制限（初回は7件で80秒かかりタイムアウト）

### 4. Prompt Template: OpportunitySimilarityInsights（✅）

- テンプレート: `OpportunitySimilarityInsights`（Flex型）
- 入力: `analysisData`（JSON文字列 — ConnectApiから直接注入）
- モデル: GPT-4o mini
- 出力構成: 現在の商談概況 → 類似商談比較 → 示唆（3-5項目） → リスク

### 5. Agent Topic: 商談類似分析（✅）

BOM_Analysis_Agent にUI（Agent Builder）で追加済み。

**Topic設定:**

| 項目 | 値 |
|---|---|
| Label | 商談類似分析 |
| Description | ユーザーが商談の類似案件、過去の参考事例、競合に勝った事例を知りたい時 |
| Scope | 指定された商談の類似商談を構造化データに基づいて検索し、インサイトを提供 |

**Instructions:**
```
1. 「類似商談分析」アクションを実行する
   - opportunityIdには現在表示中の商談のIDを渡す
2. アクションの出力（分析レポート）をそのままユーザーに返す
```

---

## 動作確認結果（2026-03-24）

### テストケース: 中部電設 九州工場 再エネ設備導入

「この商談と似た案件はありますか？」→ 4件の類似商談から分析レポートを生成。

**検出された類似商談:**

| # | 商談 | matchReason |
|---|---|---|
| 1 | アライドパワー 新拠点フルパッケージ | 同じ案件タイプ（設備導入） |
| 2 | オメガエネルギー 横浜第2拠点 | 同じ案件タイプ（設備導入） |
| 3 | 中部電設 既設風力保守 | 同じ営業アプローチ（競合リプレース） |
| 4 | サンライズ 車載ディスプレイ | 同じ緊急性の動因（事業拡大） |

**生成された示唆の質（抜粋）:**

1. **保守案件とのクロスセル戦略** — D-3（保守）とA-3（設備）をセット提案で全拠点一括管理のメリット訴求
2. **保守TCOでの価格逆転ロジック** — 台風被害時の復旧2週間という具体事例を引用してSLA比較を定量化
3. **キーパーソンとの多層的関係構築** — A-1のゴルフ・会食知見を「非公式接点での関係維持」として提案
4. **既存拠点との構成統一メリット定量化** — A-2の知見を活用
5. **既存ベンダーの障害対応事例収集** — D-3の台風被害事例を活用

→ **クラスタ横断の示唆（保守案件×設備導入のセット提案）が自然に出ている。コンセプトの実証として成功。**

---

## 実装中に遭遇した問題と対処

### 問題1: 2アクション分離パターンの失敗

**症状**: Agent LLMがApex出力のJSONをPrompt Templateに渡す際、`Invalid argument syntax. Argument list should be a valid JSON` エラーが5回繰り返され、最終的にPrompt Templateを諦めてApex出力だけで直接回答。

**原因**: primitive://String入力のmaxLength 255制限 + 大量JSONのエスケープ破損。

**対処**: 1アクション統合パターンに変更（Apex内でConnectApi経由でPrompt Template呼び出し）。

> Skill（`metadata-agentforce.md` 0-8）に警告が記載されていたが見落とした。

### 問題2: ConnectApi呼び出しのタイムアウト

**症状**: Agentforceから呼び出すと「アクション出力を取得できませんでした」エラー。匿名Apexでは成功するが約80秒かかる。

**原因**: 類似商談7件 × 全フィールドの大量JSONをPrompt Templateに渡し、GPT-4o miniの処理に80秒かかった。

**対処**: 類似商談を最大4件に削減、JSONフィールドをコンパクトに。

### 問題3: LongTextAreaのSOQLフィルタ

**症状**: `Customer_Challenge__c != null` をWHERE句に入れるとデプロイエラー。

**原因**: LongTextArea型のフィールドはSOQLのWHERE句でフィルタできない。

**対処**: Picklist型の `Sales_Process_Pattern__c != null` でSparseデータを除外。

### 問題4: Lookup（Opportunity__c）のFLS

**症状**: Bulk APIで `Field name not found: Opportunity__c` エラー。

**原因**: LookupフィールドのFLSが権限セットに含まれていなかった。

**対処**: BOM_Full_AccessにOpportunity__cのfieldPermissionsを追加。

---

## 次のステップ

### Step A: userQueryの導入（✅ 完了）

Apex Actionの入力に `userQuery` を追加し、Prompt Templateに渡すことで質問に応じた動的な回答を実現。

**実装内容:**
- Apex: `userQuery` パラメータ追加 → JSONに含めてPrompt Templateに渡す
- Prompt Template: `userQuery`がある場合はユーザーの質問に直接答えることを最優先する指示を追加
- Topic Instructions: 「毎回必ずActionを実行する」「質問が異なれば再実行」を明示 → 同一セッション内での再実行を強制（Skillに知見記録済み）

**検証結果:**
- 「競合に勝つには？」→ 競合対策の3つの具体的アクション
- 「失注するとしたら？」→ 5つのリスク要因＋対処策
- 「保守の強みをどう活かす？」→ 3つの差別化戦略
- 「関係を深めるには？」→ 4つの施策＋短期/中期/長期ロードマップ
- 同一セッション内での連続質問でもAction再実行が確認された

### Step B: 出力UIの改善（⏸ CLT保留 — 現在はString出力で運用）

**Custom Lightning Types（CLT）によるAgentforceチャット内LWCレンダリング**を試行したが、レンダラーが実行時にLWCをレンダリングしない問題が未解決。一旦String出力（マークダウン）に戻して運用。

#### CLT実装で完了していること（全てデプロイ済み）

- `OpportunitySimilarityResult` Apexクラス（global, @AuraEnabled, @JsonAccess）
- `opportunitySimilarityRenderer` LWC（カード形式＋折りたたみインサイト）
- LightningTypeBundle（schema.json + renderer.json）
- Setup → Lightning 種別 で正しく認識されている
  - チャネル: Agentforce (Lightning Experience)
  - レンダラータブ: `c/opportunitySimilarityRenderer` が紐づいている
  - コンポーネントプレビュー: LWCが表示される

#### schema.jsonの正しいフォーマット（実証済み）

```json
{
  "title": "Opportunity Similarity Result",
  "description": "類似商談分析の結果",
  "lightning:type": "@apexClassType/c__OpportunitySimilarityResult"
}
```

> ⚠️ `lightning:type` に `@apexClassType/c__ClassName` を指定する。
> `lightning__objectType` + properties手動定義ではチャネルが「エクスペリエンスビルダー」のみになりレンダラータブが出ない。

#### renderer.jsonの正しいフォーマット（実証済み）

```json
{
  "renderer": {
    "componentOverrides": {
      "$": {
        "definition": "c/opportunitySimilarityRenderer"
      }
    }
  }
}
```

#### 未解決の問題

- Agent LLMは `show` 関数で構造化データを正しく返している
- Agent Builder の出力設定で `@apexClassType/c__OpportunitySimilarityResult` を選択済み
- Lightning種別のUI設定でレンダラーが正しく紐づいている
- **しかしチャット画面（ユーザー画面・Builder両方）ではLWCがレンダリングされず、JSON生テキストが表示される**
- ブラウザコンソールにLWC関連のエラーなし
- 出力メトリクスの `type` が `copilotActionOutput/...` であり、`@apexClassType/...` になっていない

#### 調査の方向性

- Salesforceの公式サンプル（flightResponseCLTandLWC.zip等）をダウンロードして実際にデプロイし、標準サンプルで動作するか確認
- Employee Agent（InternalCopilot）でCLTが動作するための追加設定があるか
- 出力の `type` フィールドが `@apexClassType/...` になるための条件

### Step B2: LWCパネル（商談レコードページ）— ✅ 動作確認完了（2026-03-25）

CLTによるAgentforceチャット内レンダリングが未解決のため、商談レコードページに独立したLWCパネルを配置する方式に切り替え。

**デプロイ済みコンポーネント：**

| コンポーネント | 種別 | 内容 |
|---|---|---|
| `OpportunitySimilarityController` | Apex | @AuraEnabled — getInputStatus / searchAndAnalyze / createTodo |
| `OpportunitySimilaritySearchHelper` | Apex | 検索ロジック共通化（Agentforce / LWC両方から利用） |
| `OpportunitySimilarityStructured` | Prompt Template | JSON構造化出力（LWC用） |
| `opportunitySimilarityPanel` | LWC（メイン） | 入力状況 + 質問入力 + 結果表示 |
| `opportunityRecommendationCard` | LWC（子） | 推奨アクションカード + ToDo作成ボタン |
| `opportunitySimilarOppBadge` | LWC（子） | 類似商談ミニカード + リンク |

**動作確認結果：**
- 入力状況セクション: ✅ サマリ/Description/商品/活動の各ステータスと信頼度スコアが表示
- 質問入力→分析: ✅ JSON構造化レポートがカード形式で表示
- 推奨アクションカード: ✅ タイトル、根拠、アクション項目が構造化表示
- 類似商談リンク: ✅ NavigationMixinで商談レコードページに遷移
- ToDo作成: ✅（未テスト — UI上のボタンは実装済み）

**発見された重要な問題：信頼度の低い商談が参考事例として提示される**

類似商談リンクを辿った先が、現在の商談よりフェーズが手前で活動も乏しい商談だった。
ユーザーに「参考にしろ」と提示した商談がデータスカスカでは信頼を失う。

→ **サマリカード（Opportunity_Summary__c）に信頼度フィールドを追加し、検索時のフィルタに使う**方針を決定。

---

### 重要な設計変更: サマリカードへの信頼度フィールド追加（次のステップ）

**問題：**
- 類似商談として提示された商談がフェーズ初期・活動2件のみ
- 現在の「自商談の入力状況」はLWC側でリアルタイムCOUNT — これはサマリカード側に持つべき
- 検索時に信頼度でフィルタできない

**追加フィールド（Opportunity_Summary__c）：**

| フィールド | 型 | 内容 |
|---|---|---|
| `Confidence_Score__c` | Number | 信頼度スコア（1-5） |
| `Product_Count__c` | Number | 商品登録件数（生成時スナップショット） |
| `Activity_Count__c` | Number | 活動件数（生成時スナップショット） |
| `Has_Description__c` | Checkbox | Description有無 |
| `Opportunity_Stage__c` | Text | 生成時のフェーズ |

**効果：**
1. 検索時に `Confidence_Score__c >= 3` でフィルタ → 低品質商談を除外
2. フェーズのフィルタ → 現在の商談より先に進んでいる商談のみ返す
3. LWCの入力状況表示をサマリカードから取得 → リアルタイムCOUNT不要に
4. 類似商談カードにも信頼度を表示 → ユーザーが参照先の品質を事前判断

---

### Step C: サマリカードバッチ生成 + 信頼度フィールド — ✅ 実装・デプロイ完了（2026-03-25）

**問題の背景：**
- 手動投入した14件のサマリカードは品質にばらつきがあった
- 類似商談として提示された商談がフェーズ初期・活動2件のみで、参考にならない
- サマリカードの生成を自動化し、信頼度スコアで品質管理する必要がある

**実装内容：**

| コンポーネント | 種別 | 内容 |
|---|---|---|
| `Confidence_Score__c` | CustomField (Number) | 信頼度スコア（1-5） |
| `Product_Count__c` | CustomField (Number) | 商品登録件数（生成時スナップショット） |
| `Activity_Count__c` | CustomField (Number) | 活動件数（生成時スナップショット） |
| `Has_Description__c` | CustomField (Checkbox) | Description有無 |
| `Opportunity_Stage__c` | CustomField (Text) | 生成時のフェーズ |
| `OpportunitySummaryBatch` | Apex (Batchable) | 全商談対象のサマリカード自動生成バッチ |
| `OpportunitySummaryGeneration` | Prompt Template (Flex) | バッチ用PT — JSON出力でサマリカード生成 |
| リストビュー「すべて」 | ListView | 全サマリカード一覧 |
| リストビュー「信頼度 高」 | ListView | Confidence_Score >= 3 のみ |

**バッチの動作：**
1. サマリカード未生成 × Closed Lost以外の商談を対象
2. 商談ごとに入力テキスト構築（商品・活動・行動を含む）
3. `OpportunitySummaryGeneration` PT経由でLLMがJSON出力
4. 信頼度スコアを計算（Description有無、商品件数、活動件数から1-5）
5. `Opportunity_Summary__c` に保存

**信頼度スコア計算ロジック：**

| スコア | 条件 |
|---|---|
| 1 | Descriptionなし |
| 2 | Descriptionのみ |
| 3 | Description + 商品or活動あり |
| 4 | Description + 商品あり + 活動あり |
| 5 | Description + 商品3件以上 + 活動5件以上 |

**検索ロジック変更：**
- `OpportunitySimilaritySearchHelper` に `Confidence_Score__c >= 3` フィルタ追加
- 検索結果にも `Confidence_Score__c`, `Opportunity_Stage__c` を含む

**データ準備：**
- 手動投入の14件のサマリカードを全削除済み
- 7商談のフェーズを引き上げ（データ充実度に応じた適切なフェーズに調整）
- バッチランチャーに「商談 → サマリカード生成」を追加済み

**実行結果（2026-03-25）：** ✅ 完了
- バッチ実行: 43件のサマリカード生成
- 信頼度分布: スコア5が7件、スコア4が3件、スコア3が1件、スコア2が17件、スコア1が15件
- LWCパネルでの動作確認済み

**発見された問題：ハルシネーション**
- サマリカードの「商談ストーリー」等に、入力データに存在しない具体的事実が含まれていた
- 例：「設置後4年のタービンの部品交換履歴を入手済み」等 — 活動データにもDescriptionにもない情報
- 原因：Prompt Templateの指示が「推論・要約して記述」となっており、LLMが創作した
- 対処：Prompt Templateに「厳守事項（ハルシネーション防止）」セクションを追加

---

### Step C2: 面談記録（Meeting_Record__c）の組み込み — ✅ 実装・デプロイ完了（2026-03-25）

**背景：**
- 商談に紐づくMeeting_Record__cに、参加者の名前・役職、顧客の具体的発言・ニーズ、意思決定プロセスの詳細が格納されている
- Task/Eventの件名だけでは得られないリッチな情報源
- 9商談に計11件の面談記録が存在

**Meeting_Record__cの構造：**

| フィールド | 型 | 内容 |
|---|---|---|
| `Opportunity__c` | Lookup | 商談紐付け |
| `Meeting_Date__c` | Date | 面談日 |
| `Meeting_Type__c` | Picklist | 顧客訪問/Web会議/電話/展示会 |
| `Participants__c` | LongTextArea | 参加者（先方・当社） |
| `Summary__c` | LongTextArea (32KB) | 面談サマリー |
| `Transcript__c` | LongTextArea (131KB) | 文字起こし（バッチでは未使用） |

**実装内容：**

| コンポーネント | 変更 |
|---|---|
| `OpportunitySummaryBatch` | executeで面談記録を一括取得、buildInputTextに面談記録セクション追加（日付・種別・参加者・サマリー最大1000文字） |
| `OpportunitySummaryGeneration` PT | 面談記録を入力データとして明示、参加者・発言を事実データとして活用する指示追加 |
| `OpportunitySimilarityController` | getInputStatusに面談記録件数（meetingCount）追加 |
| `opportunitySimilarityPanel` LWC | 入力状況セクションに「面談:✅N件」バッジ追加、Enterキー即実行を無効化（分析ボタンのみ） |

**Prompt Templateの主な変更点：**
- 「推論・要約して記述」→「入力データに明記されている事実のみを使って要約」
- ハルシネーション防止の厳守事項4項目追加
- 面談記録の参加者・発言を事実データとして積極活用する指示
- keyStakeholdersを面談記録の参加者から抽出する指示

**効果：**
- 面談記録がある商談では、キーパーソンの名前・役職・発言内容がファクトベースでサマリカードに反映
- 面談記録がない商談でも、ハルシネーション防止により情報の捏造が抑制（不足時はnull）

**追加UI：**
- `Opportunity_Summary__c` のページレイアウト作成（6セクション: 情報/構造化分類/商談ナラティブ/活動・関係者/信頼度メトリクス/システム情報）
- FlexiPage作成（`Opportunity_Summary_Record_Page`）— 要UI有効化
- リストビュー2種（すべて / 信頼度 高）

---

### 動作確認結果（2026-03-25 最終）

#### テスト1: 中部電設 九州工場 再エネ設備導入

質問：「この商談の決め手になるアクションはなんだと思う？」

- 4件の類似商談を参照（アライドパワー既存設備リプレース、東南アジアメガソーラー、中部電設既設風力保守、サンライズディスプレイ）
- 4つの推奨アクション（保守SLA実績提示、委員会キーマン攻略、TCO比較、現地デモ）
- リスク3点（グリーンテックジャパン価格優位性、三菱電機ブランド力、既設不満の波及限界）
- **クラスタ横断の示唆**（保守案件×設備導入のセット提案）が自然に出ている

#### テスト2: 関東広域エネルギー公社 エネルギー管理PF導入

質問：「入札で高評価を得るための提案のポイントは？」

- 面談記録の鈴木主任の発言（「セキュリティ要件が厳しく、オンプレミスまたはプライベートクラウドが必須」「SCADAシステムは15年前に導入」）が**ファクトベースで**推奨アクションに反映
- 類似商談が少なくても、サマリカード自体の情報で十分な示唆が生成可能であることを確認

---

### デモシナリオ候補

#### 推奨1: 関東広域エネルギー公社 エネルギー管理PF導入（ベスト）

信頼度5 / 商品3 / 活動6 / 面談記録1件 / 公共セクター / 入札・RFP

| 質問 | 期待される回答の切り口 |
|---|---|
| 「入札で高評価を得るための提案のポイントは？」 | 鈴木主任のセキュリティ要件、SCADAリプレース、プライベートクラウド提案 |
| 「競合との差別化ポイントは？」 | 公共機関向けセキュリティ対応、既存SCADAからの移行計画 |

**デモポイント：** 面談記録のファクト引用がデモ映えする。「AIが議事録の内容を覚えていて提案に活かしている」というストーリー。

#### 推奨2: 中部電設 九州工場 再エネ設備導入（データ最多）

信頼度5 / 商品6 / 活動16 / 面談記録なし / 競合あり（拮抗）/ 競合リプレース

| 質問 | 期待される回答の切り口 |
|---|---|
| 「この商談の決め手になるアクションは？」 | 保守SLA実績、委員会攻略、TCO比較、現地デモ |
| 「競合に勝つための差別化ポイントは？」 | 保守案件のSLA実績、東南アジアの現地調査経験 |
| 「この商談のリスクと対策は？」 | グリーンテックジャパン価格優位性、三菱電機ブランド力 |

**デモポイント：** データが最も豊富で安定した回答が得られる。競合リプレースという分かりやすいシナリオ。

#### 推奨3: 東南アジア メガソーラー発電プロジェクト

信頼度5 / 商品4 / 活動7 / 面談記録2件 / 競合あり（拮抗）

| 質問 | 期待される回答の切り口 |
|---|---|
| 「キーマンへのアプローチ方法は？」 | 面談記録の参加者（役職・名前）に基づく具体的提案 |
| 「受注に向けて何が足りない？」 | 競合拮抗状態を踏まえた差別化アクション |

**デモポイント：** 面談記録2件 + 競合拮抗で最もバランスが良い。

---

### Step C3: ハルシネーション対策 — モデル変更 + 生成対象の絞り込み（2026-03-25）

**問題：**
- GPT-4o miniではPromptの厳守事項を追加してもハルシネーションが止まらない
- Claude Sonnet 4.5に変更しても、データが薄い商談では「SLAの比較が有効であることが実証されています」等、入力データの範囲を超えた表現が残る
- 根本原因：データが不十分な商談からサマリカードを作ると、LLMは少ない情報を「膨らませる」しかない

**対策：**

1. **モデル変更**: GPT-4o mini → Claude Sonnet 4.5（指示遵守能力が高い）
2. **バッチの生成対象を絞り込み**: Description必須 + 活動（Task+Event）+ 面談記録の合計が2件以上
   - `OpportunitySummaryBatch.execute()` で `String.isBlank(opp.Description) || totalActivity < 2` の場合スキップ
   - スキップ時はデバッグログに理由を出力

**モデル選択の考え方：**
- サマリカード生成（事実の要約・制約遵守型）→ Sonnet が適切
- 類似商談分析（創造的な示唆生成）→ Opus or Sonnet（横断的解釈が必要）

---

### Step D: データ拡充 + バッチ再実行 — ✅ 完了（2026-03-25）

**投入データ：**

| データ種別 | 投入件数 | 対象 |
|---|---|---|
| 面談記録（Meeting_Record__c） | 19件新規（11→30件） | 9商談に分散（中部電設九州3件、関東広域PF 2件、東南アジア1件、東日本FG 3件、北陸製薬2件、オメガ横浜2件、アライドパワー新拠点2件、中部電設保守2件、サンライズ2件） |
| Task（活動） | 47件新規 | 8商談に分散 |
| Event（行動） | 14件新規 | 7商談に分散 |
| Description追加 | 5件 | 東日本FG本店ビル、ノヴァテック生産管理、ノヴァテック工場設備、関東広域コンサル、ノヴァテック新R&D |

**データ設計方針：**
- 面談記録：商談の本筋に加えて、リアルなノイズを含む（「予算抑制のお達し」「人事異動」「余談の横展開情報」「来年度の組織変更」等）
- 活動データ：ルーティンの電話・メール・社内打合せも含め、実際のCRMに近いノイズ混じりのデータ
- LLMが「本当に重要な情報」をノイズの中から選別して示唆を生成できるかの検証も兼ねる

**バッチ実行結果：**
- 11件のサマリカード生成（エラー0）
- ハルシネーションなし — 面談記録の事実がファクトベースでサマリカードに反映
- 信頼度5が7件、4が3件、3が1件（旧1-5スケール）

**動作確認：**
- アライドパワー新拠点：「競合いたっけ？」→ 面談記録の事実（中部第1の3年間トラブルゼロ）を根拠に競合不在の優位性を活用するアクション提示
- オメガ横浜第2：「負けるとしたら？」→ 2月取締役会承認、来期予算、担当者4月異動のリスクを正確に捉え、中部電設の事例をクロスリファレンス
- 中部電設九州：サマリカードに調達部初参加による新論点、オメガ保守の問題、補助金情報等が事実ベースで記録

---

### Step E: 信頼度スコアの0-9スケール化 — ✅ 完了（2026-03-25）

**問題：**
- 旧スコア（1-5）はデータの「量」しか見ておらず、フェーズの進行度を考慮していない
- フェーズが浅い商談（Qualification等）は、活動が多くてもテレアポしているだけかもしれない
- Closed Won/Lostの商談は結末まで見えているので参考事例として最も価値が高い

**設計思想：**
- フェーズは独立した加点要素ではなく、**他の要素の価値を裏付ける軸**
- `スコア = データ充実度(0-3) × フェーズ係数(1-3)` → 0-9スケール
- 質問する側（自商談）の信頼度表示はフェーズ不問のまま（フェーズが浅くても先輩商談を参考にしたい）

**データ充実度（0-3）：**

| 値 | 条件 |
|---|---|
| 0 | Descriptionなし |
| 1 | Descriptionのみ |
| 2 | Description + (商品 or 活動+面談) |
| 3 | Description + 商品 + (活動+面談) |

**フェーズ係数（1-3）：**

| 値 | フェーズ |
|---|---|
| 1 | Discovery, Qualification |
| 2 | Proposal/Quote, DW_Proposal, DW_Prototype |
| 3 | Negotiation, Closed Won, Closed Lost |

**変更ファイル：**
- `OpportunitySummaryBatch.cls`: スコア計算ロジック変更 + `getPhaseCoefficient()` メソッド追加
- `OpportunitySimilaritySearchHelper.cls`: 検索フィルタ `>= 3` → `>= 4`

**スコア再計算結果（11件）：**

| 商談 | フェーズ | data×phase | 旧→新 |
|---|---|---|---|
| アライドパワー 新拠点 | Negotiation | 3×3 | 5→**9** |
| オメガ 横浜第2 | Negotiation | 3×3 | 5→**9** |
| 東日本FG 全店舗設備保全 | Negotiation | 2×3 | 3→**6** |
| 中部電設 九州工場 | Proposal/Quote | 3×2 | 5→**6** |
| 関東広域 エネルギー管理PF | Proposal/Quote | 3×2 | 5→**6** |
| 東南アジア メガソーラー | DW_Proposal | 3×2 | 5→**6** |
| 中部電設 既設風力保守 | Proposal/Quote | 3×2 | 4→**6** |
| Project PHOENIX | DW_Prototype | 3×2 | 4→**6** |
| サンライズ 車載ディスプレイ | DW_Prototype | 3×2 | 4→**6** |
| アライドパワー 小型風力 | Proposal/Quote | 3×2 | 5→**6** |
| 北陸製薬 エネルギー可視化 | Qualification | 3×1 | 5→**3** |

北陸製薬はデータ豊富だがQualificationのためスコア3 → フィルタ`>=4`で類似商談の参照元から除外。フェーズが進めばスコアが自動的に上がる。

---

### 次のステップ（2026-03-26〜）

| # | 内容 | 優先度 |
|---|---|---|
| **★** | **Closed Lost商談のデータ投入 + 敗因分析**（失注商談の面談記録・活動を投入し、「なぜ負けたか」の教訓を類似商談分析に活用） | **高** |
| B' | CLTのLWCレンダリング問題の解決 | 中 |
| E | より多くの商談でのテスト（スケーラビリティ検証） | 中 |
| F | 提案書の取り込み（Phase B） | 低 |
| G | フィードバック・効果測定の仕組み | 低 |
