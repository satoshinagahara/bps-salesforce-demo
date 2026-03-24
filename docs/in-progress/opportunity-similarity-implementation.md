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

### 次のステップ

| # | 内容 | 優先度 |
|---|---|---|
| **★** | **サマリカードに信頼度フィールド追加 + 検索ロジック改修** | **高** |
| B' | CLTのLWCレンダリング問題の解決 | 中 |
| C | サマリカード自動生成の仕組み（商談更新時にLLMで生成） | 中 |
| D | LWCパネルのUI改善（信頼度表示、フェーズ表示等） | 中 |
| E | より多くの商談でのテスト（スケーラビリティ検証） | 中 |
| F | 提案書の取り込み（Phase B） | 低 |
| G | フィードバック・効果測定の仕組み | 低 |
