# Salesforce Agent Script (.agent) 構文リファレンス

> 調査日: 2026-04-05
> ソース: Salesforce Developer Docs, agent-script-recipes (trailheadapps), Salesforce Developer Blog

---

## 1. 概要

Agent Scriptは、Agentforceエージェントを宣言的に定義するためのDSL（Domain-Specific Language）。
自然言語のプロンプト（`|`）と決定論的ロジック（`->`）を組み合わせた**ハイブリッド推論**が特徴。

- ファイル拡張子: `.agent`
- メタデータタイプ: `aiAuthoringBundle`
- 配置先: `force-app/main/default/aiAuthoringBundles/<BundleName>/<BundleName>.agent`
- 付随ファイル: `<BundleName>.bundle-meta.xml`

### インデント規則
- **スペースのみ**（タブ不可）、3スペース推奨
- Pythonと同様、インデントで構造を定義

### コメント
```
# 単一行コメント
```

---

## 2. ブロック構造（必須順序）

```
config:          # エージェント設定（必須）
variables:       # 変数定義
system:          # システム指示・メッセージ
  instructions:
  messages:
    welcome:
    error:
language:        # ロケール設定
connections:     # 外部接続（Omni-Channel等）
start_agent topic_selector:  # エントリポイント（必須）
topic <name>:    # トピック定義（複数可）
```

---

## 3. config ブロック

```yaml
config:
    developer_name: "MyAgent"           # 必須。APIネーム
    agent_label: "My Agent"             # 表示名
    agent_type: "AgentforceEmployeeAgent"  # エージェントタイプ
    description: "説明文"
    default_agent_user: "NEW AGENT USER"   # Service Agent向け
```

---

## 4. variables ブロック

### mutable変数（読み書き可能）
```yaml
variables:
    user_name: mutable string = ""
        description: "ユーザー名"

    age: mutable number = 0
        description: "年齢"

    is_verified: mutable boolean = False
        description: "認証済みフラグ"

    profile_data: mutable object = {}
        description: "プロフィールオブジェクト"
```

### linked変数（読み取り専用・外部ソース紐付け）
```yaml
variables:
    EndUserId: linked string
        source: @MessagingSession.MessagingEndUserId
        description: "MessagingEndUser Id"

    ContactId: linked string
        source: @MessagingEndUser.ContactId
        description: "MessagingEndUser ContactId"
```

### 型一覧
- `string` / `number` / `integer` / `long` / `boolean`
- `object` / `id`（Salesforce ID）
- `date` / `datetime` / `time` / `currency`
- `list[<type>]`（例: `list[string]`, `list[object]`）

### 変数参照
- ロジック内: `@variables.name`
- プロンプト内（テンプレート式）: `{!@variables.name}`
- オブジェクトプロパティ: `{!@variables.user_profile.name}`

### 変数代入（`->` ロジック内のみ）
```
set @variables.count = @variables.count + 1
set @variables.status = "active"
```

**注意**: `True` / `False` は大文字始まり

---

## 5. system ブロック

```yaml
system:
    instructions: "グローバルなシステム指示"
    messages:
        welcome: "ようこそ！"
        error: "エラーが発生しました。"
```

### トピック単位のsystem上書き
```yaml
topic professional:
    system:
        instructions: "あなたはフォーマルなビジネスプロフェッショナルです..."
    reasoning:
        ...
```

---

## 6. language ブロック

```yaml
language:
    default_locale: "en_US"
    additional_locales: "ja, es_MX, fr"
    all_additional_locales: False
```

---

## 7. connections ブロック

`@utils.escalate` に必要。Omni-Channel連携の設定。

```yaml
connections:
    messaging:
        escalation_message: "人間のエージェントに接続します。"
        outbound_route_type: "OmniChannelFlow"
        outbound_route_name: "AgentSupportFlow"
```

---

## 8. start_agent topic_selector ブロック

全メッセージのエントリポイント。ユーザーメッセージごとに毎回実行される。

```yaml
start_agent topic_selector:
    label: "Topic Selector"
    description: "ユーザーの入力に基づいて適切なトピックにルーティング"

    reasoning:
        instructions: |
            Select the tool that best matches the user's message.
        actions:
            go_to_orders: @utils.transition to @topic.order_management
                description: "注文関連のリクエスト"
            go_to_support: @utils.transition to @topic.support
                description: "サポートリクエスト"
                available when @variables.is_authenticated == True
```

---

## 9. topic ブロック

```yaml
topic order_management:
    label: "注文管理"                    # オプション
    description: "注文の確認・変更を処理"  # 必須

    system:                              # オプション: システム指示の上書き
        instructions: "..."

    actions:                             # アクション定義
        ...

    reasoning:                           # 推論ブロック
        instructions: ...
        actions: ...

    after_reasoning:                     # オプション: 推論後の処理
        ...
```

---

## 10. アクション定義

### 基本構文
```yaml
actions:
    get_order_status:
        description: "注文ステータスを取得"
        label: "注文ステータス取得"          # オプション
        inputs:
            order_id: string
                description: "注文ID"
                is_required: True              # オプション
            format: string
                description: "出力形式"
        outputs:
            status: string
                description: "注文ステータス"
            shipped_date: object
                description: "出荷日"
                complex_data_type_name: "lightning__dateType"
            items: list[object]
                description: "商品リスト"
                complex_data_type_name: "lightning__recordInfoType"
                filter_from_agent: True         # LLMコンテキストから除外
                is_displayable: True            # UI表示用
                is_used_by_planner: True         # プランナー利用
        target: "flow://GetOrderStatus"         # 必須
        require_user_confirmation: False         # オプション
        include_in_progress_indicator: True      # オプション
        progress_indicator_message: "検索中..."  # オプション
        source: "Get_Order_Status"               # オプション
```

### ターゲットタイプ
形式: `{TARGET_TYPE}://{DEVELOPER_NAME}`

| タイプ | 構文 | 対象 |
|--------|------|------|
| Flow | `"flow://FlowApiName"` | Autolaunched Flow |
| Apex | `"apex://ClassName"` | `@InvocableMethod` を持つApexクラス |
| Prompt Template | `"generatePromptResponse://TemplateName"` | Salesforce Prompt Template |

### Apex アクションの例
```yaml
send_weather_alert:
    description: "天気アラートを送信"
    inputs:
        message: string
            description: "アラートメッセージ"
        severity: string
            description: "重要度レベル"
    outputs:
        alertMessage: string
            description: "送信されたメッセージ"
    target: "apex://WeatherAlertService"
```

対応するApex側:
```java
public class WeatherAlertService {
    @InvocableMethod(label='Send Weather Alert')
    public static List<Output> sendAlert(List<Input> inputs) { ... }
}
```

### Flow アクションの例
```yaml
get_account_balance:
    description: "口座残高を取得"
    inputs:
        account_number: string
            description: "口座番号"
    outputs:
        balance: number
            description: "現在残高"
        account_valid: boolean
            description: "口座有効フラグ"
    target: "flow://GetAccountBalance"
```

### Prompt Template アクションの例
```yaml
generate_personalized_schedule:
    description: "パーソナライズスケジュールを生成"
    inputs:
        # Prompt Template入力は "Input:<FieldApiName>" パターン
        "Input:email": string
            description: "ユーザーのメールアドレス"
            is_required: True
    outputs:
        # Prompt Templateの出力は常にpromptResponse
        promptResponse: string
            description: "生成されたプロンプト応答"
            is_used_by_planner: True
            is_displayable: True
    target: "generatePromptResponse://Generate_Personalized_Schedule"
```

### Custom Lightning Types (CLT)
カスタムLWCコンポーネントによるリッチUI入出力:
```yaml
submit_case:
    inputs:
        case_data: object
            description: "ケース詳細"
            is_user_input: True                    # ユーザー入力UI表示
            complex_data_type_name: "c__caseInput" # カスタムLWC
    outputs:
        case_result: object
            complex_data_type_name: "c__caseResult"
            is_displayable: True
    target: "apex://CaseSubmissionService"
```

### complex_data_type_name の値
| 値 | 用途 |
|----|------|
| `lightning__dateType` | 日付型 |
| `lightning__integerType` | 整数型 |
| `lightning__textType` | テキスト型 |
| `lightning__recordInfoType` | レコード情報オブジェクト |
| `c__<lwcName>` | カスタムLightning Type（カスタムLWC） |

---

## 11. reasoning ブロック

### 構文モード

#### プロンプトモード (`|`)
LLMに渡される自然言語テキスト:
```yaml
reasoning:
    instructions: |
        ユーザーの質問に親切に回答してください。
```

#### ロジックモード (`->`)
決定論的な処理。上から順に実行され、最終的なプロンプトを組み立てる:
```yaml
reasoning:
    instructions: ->
        if @variables.user_name:
            | こんにちは、{!@variables.user_name}さん！
        else:
            | お名前を教えてください。
```

#### 混合モード（推奨パターン）
```yaml
reasoning:
    instructions: ->
        | 基本的な指示テキスト

        if @variables.status == "pending":
            run @actions.check_status
                with order_id = @variables.order_id
                set @variables.status = @outputs.current_status

            | 現在のステータス: {!@variables.status}
        else:
            | 処理完了済みです。

        | 何かお手伝いできることはありますか？
```

### 条件式
```
if @variables.name == "value":
if @variables.count > 0:
if @variables.flag:              # truthy判定
if not @variables.flag:          # falsy判定
if @variables.a and @variables.b:
if @variables.a or @variables.b:
if @variables.value is None:
if @variables.a != "":
if @variables.score >= 0.3 and @variables.score < 0.7:
```

**注意**: `else if` は非サポート。別個の `if` 文を使用。

### `run` キーワード（決定論的アクション実行）
reasoning.instructions の `->` ブロック内で使用:
```yaml
instructions: ->
    run @actions.get_timestamp
        set @variables.start_time = @outputs.current_timestamp

    run @actions.fetch_data
        with user_id = @variables.user_id
        with limit = 10
        set @variables.data = @outputs.result
```

### `set` キーワード
```
set @variables.count = @variables.count + 1
set @variables.name = "固定値"
set @variables.result = @outputs.some_output
```

### `transition to` キーワード（決定論的遷移）
```yaml
instructions: ->
    if @variables.verified:
        transition to @topic.main_flow
    else:
        transition to @topic.verification
```

---

## 12. reasoning.actions ブロック（LLM選択ツール）

LLMが状況に応じて呼び出すツールとして公開:

```yaml
reasoning:
    actions:
        # 基本: アクション参照
        get_weather: @actions.get_current_weather
            with city_name = ...          # LLMがスロットフィル
            with units = "celsius"        # 固定値
            set @variables.temp = @outputs.temperature

        # 説明の上書き
        search: @actions.search_hotels
            description: "LLMへの追加説明"
            with location = ...

        # 条件付き公開
        execute_transfer: @actions.execute_transfer
            available when @variables.validation_passed
            with from_account = @variables.source_account
            with to_account = @variables.destination_account
            with amount = @variables.transfer_amount

        # アクションチェーン（コールバック）
        make_payment: @actions.process_payment
            with amount = ...
            with method = @variables.payment_method
            set @variables.transaction_id = @outputs.transaction_id
            run @actions.send_receipt
                with transaction_id = @variables.transaction_id
                set @variables.receipt_sent = @outputs.sent
            run @actions.award_points
                with amount = @variables.payment_amount

        # 遷移付きアクション
        create_booking: @actions.create_booking
            with hotel_name = @variables.hotel_name
            set @variables.booking_id = @outputs.booking_id
            transition to @topic.confirmation
```

### 入力バインディングパターン

| パターン | 構文 | 説明 |
|----------|------|------|
| LLMスロットフィル | `with param = ...` | LLMが会話から値を抽出 |
| 固定値 | `with param = "value"` / `with param = 42` / `with param = True` | 常に固定値 |
| 変数バインド | `with param = @variables.name` | 変数の現在値を渡す |
| 混合 | 上記の組み合わせ | 用途に応じて混在可能 |

---

## 13. @utils ビルトインユーティリティ

### @utils.transition
トピック間の一方向遷移（戻りなし）:
```yaml
# reasoning.actions内（LLM選択）
go_to_orders: @utils.transition to @topic.order_management
    description: "注文管理へ遷移"
    available when @variables.authenticated == True

# reasoning.instructions内（決定論的）
instructions: ->
    transition to @topic.verification

# after_reasoning内（決定論的）
after_reasoning:
    transition to @topic.cleanup
```

### @utils.setVariables
LLMに会話から変数値を抽出させる:
```yaml
reasoning:
    actions:
        collect_info: @utils.setVariables
            description: "ユーザー情報を収集"
            with user_name = ...
            with age = ...
            with interests = ...
            with survey_completed = True  # 固定値も混在可能

        set_record_id: @utils.setVariables
            with record_id = ...  # LLMがスロットフィル

        set_confirmation: @utils.setVariables
            available when @variables.record_id != ""
            with user_confirmed = ...
```

### @utils.escalate
人間のエージェントにエスカレーション（`connections` ブロック必須）:
```yaml
connections:
    messaging:
        escalation_message: "人間のエージェントに接続します。"
        outbound_route_type: "OmniChannelFlow"
        outbound_route_name: "AgentSupportFlow"

# topic内で使用
reasoning:
    actions:
        escalate_to_human: @utils.escalate
            description: "人間のエージェントにエスカレーション"
            available when @variables.retry_count > 2
```

**注意**: `escalate` は予約語。トピック名やアクション名に使用不可。

---

## 14. after_reasoning ブロック

推論ループ終了後に毎リクエスト実行される。クリーンアップ、ログ記録、状態更新に使用。

```yaml
topic conversation:
    reasoning:
        instructions: ->
            ...

    after_reasoning:
        set @variables.turn_count = @variables.turn_count + 1

        run @actions.log_event
            with event_type = "reasoning_completed"
            with event_data = "Turn {!@variables.turn_count} completed"

        if @variables.should_redirect:
            transition to @topic.next_step
```

**制約**:
- `|`（パイプ）コマンドは使用不可（プロンプトテキストは書けない）
- 途中でトピック遷移が起きた場合、元トピックの `after_reasoning` は実行されない
- `transition to` を使用（`@utils.transition to` ではない）

**`before_reasoning`** ブロックも存在し、同等の構文で推論前に実行される。

---

## 15. `available when` 条件（ガード）

reasoning.actions とstart_agent内のアクションに条件を付けて、LLMからの可視性を制御:

```yaml
actions:
    # 変数条件
    execute_transfer: @actions.execute_transfer
        available when @variables.validation_passed

    # 比較条件
    view_booking: @utils.transition to @topic.confirmation
        available when @variables.booking_confirmed == True

    # 複合条件
    delete_record: @actions.delete_record
        available when @variables.delete_state == "ready" and @variables.dependency_count == 0

    # 否定条件
    check_dependencies: @actions.check_dependencies
        available when @variables.confirmed == True
```

条件が満たされない場合、そのアクションはLLMのツール一覧に表示されない。

---

## 16. アクション参照（プロンプト内）

プロンプトテキスト内でアクションを参照してLLMに使用を促す:
```yaml
instructions: ->
    | 注文IDが分かったら {!@actions.get_order_status} を使って確認してください。
    | {!@actions.create_case} でサポートケースを作成します。
```

---

## 17. 標準ライブラリ関数

### テキスト関数
- `text.contains(haystack, needle)` - 文字列包含判定
- `text.concat(str1, str2)` - 文字列連結
- `text.is_empty(str)` - 空文字列判定

### リスト関数
- `list.length(list)` - リスト長取得
- `list.contains(list, item)` - リスト包含判定
- `list.add(list, item)` - リストに追加（mutable）

### 日付関数
- `date.today()` - 今日の日付
- `date.now()` - 現在日時

---

## 18. 比較・論理演算子

| 演算子 | 説明 |
|--------|------|
| `==` | 等しい |
| `!=` | 等しくない |
| `<`, `>`, `<=`, `>=` | 比較 |
| `and` | 論理AND |
| `or` | 論理OR |
| `not` | 論理NOT |
| `is None` | null判定 |
| `+`, `-`, `*`, `/` | 算術演算 |

---

## 19. デプロイメントワークフロー

### ライフサイクル

```
.agent ファイル編集
    ↓
sf agent validate authoring-bundle   # コンパイル検証
    ↓
(Apex/Flowの変更があれば先にデプロイ)
sf project deploy start --source-dir ...
    ↓
sf agent publish authoring-bundle    # org にパブリッシュ
    ↓
Bot + BotVersion + GenAiXX メタデータ自動生成
AiAuthoringBundle メタデータもデプロイ
```

### 重要ポイント

1. **直接編集可能**: `.agent` ファイルを直接テキストエディタで編集してOK
2. **Agentforce Builder との等価性**: `publish` = Builder UI の「バージョンをコミット」ボタン
3. **依存リソースは先にデプロイ**: Apex や Flow を変更した場合、`sf agent publish` の前に `sf project deploy start` が必要
4. **バリデーション**: `sf agent validate authoring-bundle` でコンパイルエラーを事前チェック
5. **取得**: パブリッシュ後、生成されたメタデータは自動的にDXプロジェクトに取得される（`--skip-retrieve` で省略可）
6. **ドラフトのみパブリッシュ可**: バージョニングされたバンドルは再パブリッシュ不可

### bundle-meta.xml
```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiAuthoringBundle xmlns="http://soap.sforce.com/2006/04/metadata">
  <bundleType>AGENT</bundleType>
</AiAuthoringBundle>
```

### CLI コマンド一覧

| コマンド | 説明 |
|----------|------|
| `sf agent generate authoring-bundle` | 新規バンドル生成（agent specから or --no-spec） |
| `sf agent validate authoring-bundle` | .agent ファイルのコンパイル検証 |
| `sf agent publish authoring-bundle` | org にパブリッシュ（メタデータ生成） |
| `sf agent preview` | 対話的プレビュー |
| `sf agent activate` | エージェントを有効化 |
| `sf agent deactivate` | エージェントを無効化 |

---

## 20. 完全な実装例

### Employee Agent（Apex + Flow混在）

```
config:
    developer_name: "BOMSalesAgent"
    agent_label: "BOM営業支援エージェント"
    agent_type: "AgentforceEmployeeAgent"
    description: "商談データの分析と提案書作成を支援"

variables:
    account_id: mutable string = ""
        description: "対象取引先ID"
    opportunity_data: mutable object = {}
        description: "商談データ"
    analysis_result: mutable string = ""
        description: "分析結果"

system:
    instructions: "あなたはBOM営業チームの支援エージェントです。日本語で応答してください。"
    messages:
        welcome: "BOM営業支援エージェントです。どのようにお手伝いしますか？"
        error: "エラーが発生しました。再度お試しください。"

language:
    default_locale: "ja"

start_agent topic_selector:
    description: "ユーザーリクエストを適切なトピックにルーティング"

    reasoning:
        instructions: |
            ユーザーのメッセージに最も合うツールを選択してください。
        actions:
            go_to_analysis: @utils.transition to @topic.opportunity_analysis
                description: "商談分析・パイプライン確認"
            go_to_proposal: @utils.transition to @topic.proposal_support
                description: "提案書作成支援"

topic opportunity_analysis:
    description: "商談データの分析とインサイト提供"

    actions:
        search_opportunities:
            description: "取引先の商談一覧を検索"
            inputs:
                account_id: id
                    description: "取引先ID"
            outputs:
                opportunities: list[object]
                    description: "商談リスト"
                    complex_data_type_name: "lightning__recordInfoType"
            target: "flow://SearchOpportunitiesByAccount"

        analyze_pipeline:
            description: "パイプラインを分析してインサイトを生成"
            inputs:
                account_id: id
                    description: "取引先ID"
                opportunities: list[object]
                    description: "分析対象の商談リスト"
                    complex_data_type_name: "lightning__recordInfoType"
            outputs:
                analysis: string
                    description: "分析レポート"
                risk_score: number
                    description: "リスクスコア"
            target: "apex://PipelineAnalysisService"

    reasoning:
        instructions: ->
            if @variables.account_id == "":
                | 取引先IDまたは取引先名を教えてください。
                  {!@actions.set_account} で取引先を設定します。
            else:
                run @actions.search_opportunities
                    with account_id = @variables.account_id
                    set @variables.opportunity_data = @outputs.opportunities

                | 取引先 {!@variables.account_id} の商談データ:
                  {!@variables.opportunity_data}

                  分析が必要な場合は {!@actions.analyze_pipeline} を使用してください。

        actions:
            set_account: @utils.setVariables
                with account_id = ...

            search: @actions.search_opportunities
                with account_id = @variables.account_id

            analyze: @actions.analyze_pipeline
                available when @variables.account_id != ""
                with account_id = @variables.account_id
                with opportunities = @variables.opportunity_data
                set @variables.analysis_result = @outputs.analysis
```

---

## 参考リンク

- [Agent Script 公式ガイド](https://developer.salesforce.com/docs/ai/agentforce/guide/agent-script.html)
- [Agent Script リファレンス](https://developer.salesforce.com/docs/ai/agentforce/guide/ascript-reference.html)
- [Actions リファレンス](https://developer.salesforce.com/docs/ai/agentforce/guide/ascript-ref-actions.html)
- [Utils リファレンス](https://developer.salesforce.com/docs/ai/agentforce/guide/ascript-ref-utils.html)
- [After Reasoning リファレンス](https://developer.salesforce.com/docs/ai/agentforce/guide/ascript-ref-before-after-reasoning.html)
- [Reasoning Instructions リファレンス](https://developer.salesforce.com/docs/ai/agentforce/guide/ascript-ref-instructions.html)
- [Agentforce DX: Agent Script コーディング](https://developer.salesforce.com/docs/ai/agentforce/guide/agent-dx-nga-script.html)
- [Agentforce DX: パブリッシュ](https://developer.salesforce.com/docs/ai/agentforce/guide/agent-dx-nga-publish.html)
- [Agent Script Recipes (GitHub)](https://github.com/trailheadapps/agent-script-recipes)
- [Agent Script Decoded ブログ (2026/02)](https://developer.salesforce.com/blogs/2026/02/agent-script-decoded-intro-to-agent-script-language-fundamentals)
- [Agentforce.Guide (非公式)](https://agentforce.guide/)
