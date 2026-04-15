# Agentforce 2.0 設計書

> 作成日: 2026-04-14（大幅改訂: 2026-04-15）
> ステータス: 設計中
> コンセプト: [docs/concepts/agentforce-2.0-concept.md](../concepts/agentforce-2.0-concept.md)

---

## 改訂履歴

| 日付 | 変更内容 |
|---|---|
| 2026-04-14 | 初版作成。自作MCPサーバー10ツール前提で設計 |
| 2026-04-15 | **全面改訂**。Salesforce Hosted MCP (GA) の実態判明により、自作MCP路線から「標準MCP + Custom MCP + Agent Runtime」の4層構成に再設計。MuleSoft依存なし |

---

## 1. ゴール

Salesforce純正Agentforceの構造的制約（Topic境界、一問一答、状態なし）を超え、**自由対話・自律ツール選択・マルチターン深掘り**をSalesforce画面内（LWC薄チャット）から提供する。

### 達成条件（PoC）

キラーデモシナリオがSalesforce LWC上で通しで動作：

1. 自然言語での自由条件指定 → リード/商談の抽出
2. 「この10件でリストビュー作って」→ 作成
3. 「このリストにパーソナライズメール下書き作って」→ 複数件作成

### 副次目標（BPSデモ固有）

4. Sales Agreement計画vs実績の乖離分析を自然対話で実行（Manufacturing Cloud 2.0との統合）
5. 既存Apex Invocable資産（BOM分析、Account Insight等）をAgentforce 2.0経由で呼び出し

---

## 2. アーキテクチャ：4層構成

### 2.1 全体図

```
┌─────────────── Layer 4: Salesforce UI ───────────────┐
│                                                        │
│  [LWC agentforce2Chat] ユーティリティバー配置         │
│   ├ チャット入力・表示                                 │
│   ├ ファイルドロップ（CSV/PDF対応）                    │
│   ├ レコードコンテキスト自動検出                       │
│   └ empApi: Platform Event subscribe                   │
│         │                                              │
│  [Apex: Agentforce2Service + Queueable]                │
│   └ Named Credential経由でAgent Runtimeへ非同期Callout │
│                                                        │
│  [Platform Event: Agentforce2_Response__e]             │
│                                                        │
└──────────────────┬─────────────────────────────────────┘
                   │ HTTPS
                   ▼
┌─────────────── Layer 3: Agent Runtime (自作) ─────────┐
│                                                        │
│  [Cloud Run: FastAPI]                                  │
│   ├ セッション管理（インメモリ → Redis）               │
│   ├ Agent Loop（LLM + MCPクライアント）                │
│   ├ LLM Client抽象化（Claude/Gemini/Gemma切替可）      │
│   └ Platform Event Publish（Salesforceへ応答返送）     │
│                                                        │
└──────────────────┬─────────────────────────────────────┘
                   │ MCP Protocol
                   ▼
┌─────────────── Layer 1+2: MCPサーバー層 ──────────────┐
│                                                        │
│  Layer 1: 標準Salesforce Hosted MCP Servers           │
│   （自作ゼロ、有効化するだけ）                         │
│   ├ sobject-all            (9 tools + 2 prompts)      │
│   ├ sobject-reads          (6 tools)                  │
│   ├ sobject-mutations      (6 tools)                  │
│   ├ sobject-deletes        (8 tools)                  │
│   ├ salesforce-api-context (6 tools)                  │
│   ├ data-cloud-queries     (2 tools)                  │
│   └ metadata-experts       (1 tool)                   │
│                                                        │
│  Layer 2: Custom MCP Server（宣言的定義、自作ゼロ）    │
│   McpServerDefinition: bps-agentforce2-custom          │
│   ├ Tool: createPersonalListView                       │
│   │       ApiSource: Invocable (新規Apexクラス)        │
│   ├ Tool: bomSupplierImpact                            │
│   │       ApiSource: Invocable                         │
│   │       ApiIdentifier: 既存BOMAnalysisGetSupplierImpact│
│   ├ Tool: accountInsight                               │
│   │       ApiSource: Invocable                         │
│   │       ApiIdentifier: 既存AccountInsightFullAnalysis│
│   ├ Prompt: bpsAgreementReconciliation                 │
│   │       既存Prompt Templateを書き換え                │
│   └ Prompt: bpsDesignWinProgression                    │
│                                                        │
│   認証: Per-User OAuth 2.0 with PKCE（ネイティブ）    │
│                                                        │
└────────────────────┬───────────────────────────────────┘
                     │ REST API (user token)
                     ▼
              [Salesforce Org]
```

### 2.2 各層の責務

| 層 | 役割 | 実装 |
|---|---|---|
| Layer 4 | Salesforce内UI + 非同期通信 | LWC + Apex（自作） |
| Layer 3 | LLM + Agent Loop + MCPクライアント | Cloud Run上のFastAPI（**唯一の自作サービス**） |
| Layer 2 | このorg固有のツール/プロンプト | メタデータ定義のみ（コード作成はほぼなし）|
| Layer 1 | 汎用Salesforce操作ツール | Salesforce標準機能（有効化のみ） |

**自作する「コード」は Layer 3 と Layer 4 のみ**。Layer 1/2 はメタデータ定義で済む。

### 2.3 コスト構成（デモ環境）

| コンポーネント | サービス | 月額目安 |
|---|---|---|
| Agent Runtime | Cloud Run (CPU only) | $0〜10 |
| LLM推論 | Claude API (Sonnet) | $5〜30 |
| 会話履歴 | インメモリ | $0 |
| Salesforce Hosted MCP | Platform内（GA料金詳細は未確定）| 現時点不明 |
| **合計** | | **$5〜40 + ライセンス** |

MuleSoft依存なし。GPU VM不要。

---

## 3. Layer 1: 標準Hosted MCPサーバー

### 3.1 有効化する標準サーバー

このorgの Setup → MCPサーバー で以下7サーバーが選択可能（全て「標準」種別）：

| サーバー | ツール数 | プロンプト数 | PoCでの採用 |
|---|---|---|---|
| **sobject-all** | 9 | 2 | ✅ 主力 |
| sobject-reads | 6 | 0 | 重複するため非採用（sobject-allに含まれる）|
| sobject-mutations | 6 | 0 | 重複のため非採用 |
| sobject-deletes | 8 | 0 | △ 破壊的操作、デモでは慎重に |
| **salesforce-api-context** | 6 | 0 | ✅ 採用候補（要インベントリ確認）|
| **data-cloud-queries** | 2 | 0 | ✅ 採用（このorgはData Cloud活用済）|
| metadata-experts | 1 | 0 | △ 管理者作業向け、一般ユーザーには不要 |

### 3.2 sobject-all の9ツール（確認済）

| ツール名 | 機能 | Agentforce 2.0での用途 |
|---|---|---|
| `soqlQuery` | 自由文SOQL実行 | **キラーデモの心臓部** |
| `find` (SOSL) | マルチオブジェクト横断検索 | 曖昧検索 |
| `getObjectSchema` | LLM最適化スキーマ取得（picklist値含む想定）| SOQL構築前の確認 |
| `getRelatedRecords` | 関係辿り（マルチレベル）| `Account/Opportunities`等 |
| `listRecentSobjectRecords` | ユーザーが最近見たレコード | 「さっき見てたやつ」解決 |
| `getUserInfo` | 現在ユーザーの情報 | パーソナライズ判断 |
| `createSobjectRecord` | 汎用レコード作成 | EmailMessage Draftもこれで作る |
| `updateSobjectRecord` | 汎用更新 | |
| `updateRelatedRecord` | 関係パス経由の子レコード更新 | 子IDを知らなくても書ける |

### 3.3 sobject-allの標準プロンプト2つ（確認済）

1. **`einstein_gpt__accountReviewBriefing`**: アカウントレビュー用エグゼクティブブリーフィング（Web検索含む6ステップ）
2. **`einstein_gpt__revenueReconciliationAnalysis`**: GL CSV と Closed Won商談の乖離分析（ファイルアップロード対応）

両方とも `Standard-Overrideable` カテゴリなので、**このorg固有にカスタマイズ可能**。

### 3.4 標準ツールでの不足部分（ギャップ）

キラーデモシナリオに対するギャップ：

| 必要機能 | 標準ツールでの対応 | ギャップ |
|---|---|---|
| SOQL実行 | `soqlQuery` | ✅ 完全対応 |
| スキーマ確認 | `getObjectSchema` | ✅ 完全対応 |
| 選択リスト値（日本語）| `getObjectSchema` 内包見込（要検証）| △ 要検証 |
| リード作成/更新 | `createSobjectRecord` / `updateSobjectRecord` | ✅ 完全対応 |
| **ListView動的作成** | **なし** | ❌ **Custom Serverで補完**|
| EmailMessage Draft作成 | `createSobjectRecord` で対応可能 | △ 要検証（Draft Statusが作成時指定可か）|
| BOM分析カスタムロジック | なし | ❌ Custom Serverで補完 |
| 業務固有プロンプト | なし | ❌ Custom Serverで追加 |

---

## 4. Layer 2: Custom MCP Server

### 4.1 設計方針

Layer 1の不足を補う **このorg専用のMCPサーバー**を `McpServerDefinition` メタデータで宣言的に構築する。**自作コードは最小限**、**既存のApex Invocable / Prompt Template資産を最大限再利用**する。

### 4.2 Custom Server の構成

```
McpServerDefinition
  DeveloperName: bps_agentforce2_custom
  MasterLabel: BPS Agentforce 2.0 Custom Tools
  Description: BPS特化のツール・プロンプトを束ねる

  McpServerAccess
    Active: true

  McpServerToolDefinition （複数）
    - name: createPersonalListView
    - name: bomSupplierImpact
    - name: accountInsight
    - name: bomFullAnalysis
    - name: opportunitySimilaritySearch

  McpServerPromptDefinition （複数）
    - name: bpsAgreementReconciliation
    - name: bpsDesignWinProgression
    - name: bpsBomRiskAssessment
```

### 4.3 提供するツール詳細

#### 4.3.1 createPersonalListView（**新規Apex Invocable必要**）

| 項目 | 内容 |
|---|---|
| ApiSource | Invocable |
| ApiIdentifier | `Agentforce2_CreateListView` |
| 新規Apex | `Agentforce2CreateListView.cls`（InvocableMethod）|
| 機能 | 指定SObjectと条件で個人リストビューをTooling API経由で作成 |
| 入力 | `sobjectName`, `label`, `filterScope='Mine'`, `recordIdList` |
| 出力 | 作成されたListViewのIDとURL |
| 代替案 | IN句がToolingで問題になる場合、`Lead_Selection__c`等の中間オブジェクト方式に切替 |

#### 4.3.2 既存資産の再利用（**コード追加ゼロ**）

| Custom Serverツール名 | 紐付ける既存Apex Invocable | 用途 |
|---|---|---|
| `bomSupplierImpact` | `BOMAnalysisGetSupplierImpact` | サプライヤー影響分析 |
| `accountInsight` | `AccountInsightFullAnalysis` | 取引先の統合インサイト |
| `bomFullAnalysis` | `BOMAnalysisGetProductBOM` | 製品BOM構造取得 |
| `opportunitySimilaritySearch` | 既存の類似商談検索ロジック | 類似商談発見 |

これらは全て `McpServerToolApiDefinition` レコードを作成し `ApiIdentifier` に既存Apexクラス名を指定するだけで完了。

#### 4.3.3 ツール候補（将来検討）

| ツール | 検討事項 |
|---|---|
| `drawAnalysisSubmit` | 図面解析（Gemma 4連携）。ファイルアップロード対応 |
| `revenueForecastSum` | Revenue_Forecast__c合算（Manufacturing Cloud 2.0連携）|
| `designWinStageTransition` | Design Win → Sales Agreement自動化 |

### 4.4 提供するプロンプト

#### 4.4.1 bpsAgreementReconciliation（**新規、`revenueReconciliationAnalysis` の流用**）

標準の `revenueReconciliationAnalysis` プロンプトは汎用的なので、BPSの `Sales_Agreement_Schedule__c` 構造向けに書き換え：

```
Input Parameters:
  - salesAgreementId: 対象契約のID
  - lookbackMonths: 遡及月数（デフォルト12）
  - varianceThreshold: 許容乖離率（デフォルト5%）

Step 1: Sales_Agreement_Schedule__c から計画値取得
  soqlQuery: SELECT Id, Year_Month__c, Planned_Quantity__c, Planned_Amount__c,
                    Actual_Quantity__c, Actual_Amount__c
             FROM Sales_Agreement_Schedule__c
             WHERE Sales_Agreement__c = :salesAgreementId
               AND Year_Month__c >= LAST_N_MONTHS:lookbackMonths

Step 2: 月別の計画vs実績乖離を計算

Step 3: 乖離要因の候補を推論
  - 数量乖離 vs 単価乖離の分離
  - BOMサプライヤー変更の可能性（bomSupplierImpactを呼び出し）
  - 需要変動パターン

Step 4: エグゼクティブ向けレポート生成（構造化フォーマット）
```

#### 4.4.2 bpsDesignWinProgression

Design Win商談の進捗を分析し、次アクションを提案するプロンプト。Manufacturing Cloud 2.0のPhase 1ライフサイクルと統合。

#### 4.4.3 bpsBomRiskAssessment

BOM構造からサプライヤーリスクを包括的に評価するプロンプト。既存の`bomSupplierImpact`ツールと組み合わせ。

#### 4.4.4 既存Prompt Templateの束ね（**追加作業ほぼゼロ**）

このorgに既にある13個のPrompt TemplateをMcpServerPromptDefinitionレコードで紐付けるだけで全てMCP経由で呼べるようになる。

---

## 5. Layer 3: Agent Runtime

Layer 1/2 はSalesforceが提供/ホストする層。Layer 3 が**唯一の自作サービス**。

### 5.1 技術スタック

| 項目 | 採用 |
|---|---|
| 言語 | Python 3.12 |
| フレームワーク | FastAPI |
| MCPクライアント | `mcp` 公式Python SDK |
| LLM SDK | `anthropic`（Claude）、`google-genai`（Gemini）、`openai`（ローカルGemma 4） |
| セッション管理 | インメモリ（dict）→ 将来Redis |
| デプロイ | Google Cloud Run |

### 5.2 APIエンドポイント

```
POST /chat
  Request:
    {
      "session_id": "uuid",
      "message": "リードを抽出して",
      "context": {
        "record_id": "001xx...",
        "object_api_name": "Account",
        "user_id": "005xx..."
      },
      "sf_access_token": "Bearer ...",  # Apex Named Credentialから転送
      "sf_instance_url": "https://xxx.my.salesforce.com",
      "callback": {
        "type": "platform_event",
        "event_name": "Agentforce2_Response__e"
      },
      "attachments": [  # 任意、ファイルアップロード用
        { "filename": "gl.csv", "content_type": "text/csv", "base64": "..." }
      ]
    }

  Response (即座):
    { "status": "accepted", "session_id": "uuid" }
```

### 5.3 Agent Loop

```python
async def agent_loop(session_id: str, user_message: str, context: dict,
                     sf_token: str, sf_instance: str):
    # 1. MCPクライアント初期化（標準 + Custom Server両方接続）
    mcp_standard = MCPClient(
        endpoint=f"https://api.salesforce.com/platform/mcp/v1/platform/sobject-all",
        auth_token=sf_token,
    )
    mcp_custom = MCPClient(
        endpoint=f"{sf_instance}/services/data/v66.0/mcp/v1/custom/bps_agentforce2_custom",
        auth_token=sf_token,
    )

    # 2. 利用可能な全ツール・プロンプトを集約
    tools = mcp_standard.list_tools() + mcp_custom.list_tools()
    prompts = mcp_standard.list_prompts() + mcp_custom.list_prompts()

    # 3. セッション履歴取得
    history = session_manager.get(session_id)
    history.append({"role": "user", "content": user_message})

    # 4. Agent Loop
    for i in range(MAX_ITERATIONS):  # safety limit = 20
        response = await llm_client.chat(
            system=SYSTEM_PROMPT.format(context=context),
            messages=history,
            tools=tools,
        )

        if response.stop_reason == "tool_use":
            for tool_call in response.tool_calls:
                mcp_client = mcp_custom if is_custom(tool_call.name) else mcp_standard
                result = await mcp_client.call_tool(tool_call.name, tool_call.args)
                history.append(tool_use_message(tool_call))
                history.append(tool_result_message(result))
        else:
            # 最終応答
            await publish_platform_event(sf_token, sf_instance, session_id,
                                         response.text, status="complete")
            history.append({"role": "assistant", "content": response.text})
            break

    session_manager.save(session_id, history)
```

### 5.4 System Prompt

```
あなたはSalesforce上で営業担当者を支援するAIアシスタントです。

## 能力
- Salesforceのデータをクエリ・作成・更新できます（MCPツール経由）
- BOM分析、サプライヤーリスク評価、商談類似検索ができます（Custom Tool）
- 複数のツールを組み合わせて、マルチステップの分析・アクションが可能です
- 前の会話の結果を踏まえて、追加のアクションを自律的に実行できます

## 重要なルール
1. SOQLを組む前に、getObjectSchema でフィールド名と選択リスト値を確認する
   この環境では選択リスト値は全て日本語
2. レコードの作成・更新・削除を行う前に、その内容をユーザーに提示して確認を得る
   （ユーザーが「そのまま作って」等と言った場合は確認不要）
3. 結果が大量の場合は要約して表示し、「全件見ますか？」と聞く
4. エラー時はエラー内容を伝え、代替案を提示する

## コンテキスト
- 現在表示中のレコード: {record_id} ({object_api_name})
- ユーザーID: {user_id}
```

### 5.5 LLM Client抽象化

```python
class LLMClient(Protocol):
    async def chat(
        self,
        system: str,
        messages: list[dict],
        tools: list[dict],
    ) -> LLMResponse: ...

# 環境変数 LLM_PROVIDER で切替
# - claude: Anthropic SDK（デフォルト）
# - gemini: Google GenAI SDK
# - local:  OpenAI互換（ローカルGemma 4 mlx-lm）
```

---

## 6. Layer 4: Salesforce UI

### 6.1 LWC: agentforce2Chat

**配置**: ユーティリティバー（全画面共通）+ 必要に応じてレコードページにも

```
agentforce2Chat/
  ├ agentforce2Chat.html
  ├ agentforce2Chat.js
  ├ agentforce2Chat.css
  └ agentforce2Chat.js-meta.xml
```

**主要機能**:
- テキスト入力 + 送信ボタン
- ファイルドロップ（CSV/PDF対応）
- メッセージ表示（user / assistant、Markdownレンダリング）
- 「思考中...」インジケータ
- `empApi` による `Agentforce2_Response__e` subscribe
- レコードページ配置時は `@api recordId` で自動コンテキスト取得
- セッションID生成（`crypto.randomUUID()`相当）
- ページ遷移時にセッションリセット

**状態**:
- LWCは表示用キャッシュのみ
- 真の会話履歴はAgent Runtime側

### 6.2 Apex層

#### Agentforce2Service.cls (@AuraEnabled)

```apex
public class Agentforce2Service {

    @AuraEnabled
    public static String sendMessage(String sessionId, String message,
                                      String recordId, String objectApiName,
                                      List<Map<String,String>> attachments) {
        Agentforce2Callout job = new Agentforce2Callout(
            sessionId, message, recordId, objectApiName,
            UserInfo.getUserId(), attachments
        );
        Id jobId = System.enqueueJob(job);
        return jobId;
    }
}
```

#### Agentforce2Callout.cls (Queueable + AllowsCallouts)

Named Credential経由でAgent Runtimeに非同期POST。同期Calloutしたら即時終了（Agent側の処理完了を待たない）。応答はPlatform Event経由で非同期受信。

### 6.3 Platform Event: Agentforce2_Response__e

| フィールド | 型 | 説明 |
|---|---|---|
| Session_Id__c | Text(100) | LWCセッションIDと一致 |
| Message__c | Long Text(131072) | 応答（Markdown）|
| Status__c | Text(20) | `streaming` / `complete` / `error` |
| Metadata__c | Long Text(32768) | ツール実行サマリ等のJSON |

Agent RuntimeがSalesforce REST API経由でPublish：

```python
async def publish_platform_event(token, instance, session_id, message, status):
    url = f"{instance}/services/data/v66.0/sobjects/Agentforce2_Response__e"
    await httpx.post(url, json={
        "Session_Id__c": session_id,
        "Message__c": message,
        "Status__c": status,
    }, headers={"Authorization": f"Bearer {token}"})
```

---

## 7. 認証フロー

### 7.1 2つの認証パス

```
[LWC] ──Apex Callout──▶ [Agent Runtime]
         │
         Named Credential
         (JWT Bearer or OAuth Auth Provider)
         │
         ユーザーのaccess_tokenを取得・転送
         │
         ▼
    [Agent Runtime]
         │
         ├─▶ Salesforce Hosted MCP
         │   Authorization: Bearer {user_token}
         │   (Per-User OAuth 2.0 PKCE - ネイティブ対応)
         │
         └─▶ Custom MCP Server（同orgに同居）
             Authorization: Bearer {user_token}
             (同じtokenで認証、FLS・共有ルール継承)
```

### 7.2 Per-User OAuth PKCE（Hosted MCPのネイティブ機能）

**決定的な設計上の勝利点**: Salesforce Hosted MCPが**Per-User OAuth 2.0 with PKCE**をネイティブ対応しているため、我々は認証機構を一切自作不要。

- 各ユーザーが初回接続時にOAuth認可画面を通過
- Salesforce側でtoken管理（リフレッシュも自動）
- MCPサーバー内で Running User = そのユーザー本人
- FLS・共有ルール・監査ログが全てネイティブで機能

### 7.3 Named Credential設定

| 項目 | 値 |
|---|---|
| Label | Agentforce2 Runtime |
| Name | Agentforce2_Runtime |
| URL | (Cloud RunのエンドポイントURL) |
| Identity Type | Named Principal（PoC）or Per User（本番）|
| Authentication Protocol | OAuth 2.0 |

---

## 8. データフロー（全体）

### 8.1 メッセージ送受信シーケンス

```
[LWC]
  │ (1) sendMessage() @AuraEnabled
  ▼
[Apex Agentforce2Service]
  │ (2) Queueable enqueue → jobId返却
  │     LWCはローディング表示
  ▼
[Queueable Agentforce2Callout]
  │ (3) Named Credential経由で HTTPS POST /chat
  │     user_token を Authorization ヘッダに自動付与
  ▼
[Agent Runtime (Cloud Run)]
  │ (4) 202 Accepted返却、Queueable完了
  │
  │ (5) 非同期でAgent Loop開始
  │     a. MCP Clientで標準 + Custom Serverに接続
  │     b. tools/prompts一覧取得
  │     c. LLM呼び出し
  │     d. tool_use → MCP経由で実行 → 結果 → 繰り返し
  │     e. text応答 → Platform Event Publish
  │
  ▼
[Salesforce Event Bus]
  │ (6) Agentforce2_Response__e 発火
  ▼
[LWC]
  │ (7) empApi subscription fire
  │ (8) Session_Id一致確認 → チャット表示更新
  └ (9) Status='complete' → ローディング終了
```

### 8.2 タイミング見積

| ステップ | 所要時間 |
|---|---|
| (1)(2) LWC→Apex→Queueable | < 1秒 |
| (3) Callout to Cloud Run | 1〜3秒 |
| (5) Agent Loop（ツール0〜5回）| 5〜40秒 |
| (6)(7)(8) Event → LWC | < 2秒 |
| **合計** | **7〜46秒** |

---

## 9. 実装フェーズ

### Phase 0: 実地検証（~1日）

**目標**: ホステッドMCPの実体を把握

- [ ] sobject-all の「有効化」ボタン押下、External Client App作成（必要なら）
- [ ] Claude Desktop から接続設定（MCPクライアント config）
- [ ] キラーデモシナリオをClaude Desktopで試行
- [ ] **ListView作成の代替手段**を実地で検証
- [ ] picklist日本語値がgetObjectSchemaで取れるか確認

**成果物**: 実地検証メモ、設計確度の大幅向上

### Phase 1: Custom MCP Server構築（~1週間）

**目標**: BPS特有のツール・プロンプトをMCPに露出

- [ ] `McpServerDefinition: bps_agentforce2_custom` 作成
- [ ] 新規Apex `Agentforce2CreateListView` 実装（ListView補完）
- [ ] 既存Apex Invocable（BOM分析、Account Insight等）をMcpServerToolDefinitionに紐付け
- [ ] カスタムプロンプト `bpsAgreementReconciliation` 作成
- [ ] 既存13個のPrompt TemplateをMcpServerPromptDefinitionで束ねる
- [ ] Claude Desktopから Custom Server も含めた動作確認

**成果物**: BPS特化のMCPサーバー、Claude Desktop経由で利用可能

### Phase 2: Agent Runtime（~1週間）

**目標**: Salesforceから叩けるAgent Runtimeをデプロイ

- [ ] FastAPI雛形（POST /chat エンドポイント）
- [ ] MCP Client実装（標準 + Custom両対応）
- [ ] Agent Loop実装
- [ ] LLM Client抽象化（Claude / Gemini / Local）
- [ ] Platform Event Publish実装
- [ ] Cloud Runデプロイ（min-instances=1でcold start回避）

**成果物**: Cloud Run上で動くAgent Runtime

### Phase 3: Salesforce UI統合（~1-2週間）

**目標**: LWC薄チャットから通しで動作

- [ ] Platform Event `Agentforce2_Response__e` 作成
- [ ] Apex `Agentforce2Service` + `Agentforce2Callout` 実装
- [ ] Named Credential設定
- [ ] LWC `agentforce2Chat` 実装
- [ ] ユーティリティバー配置
- [ ] キラーデモ通し試験

**成果物**: Salesforce内で動くAgentforce 2.0

### Phase 4: 拡張（Week 6-）

- [ ] 図面解析モード（Gemma 4連携、ファイルアップロード）
- [ ] 会話履歴の永続化（Redis / Firestore）
- [ ] ストリーミング応答（SSE → Platform Event逐次）
- [ ] エラーリカバリ、レート制限、監査ログ

---

## 10. 技術リスクと対策

| リスク | 確率 | 対策 |
|---|---|---|
| Hosted MCP料金体系がGA時に高額 | 中 | Phase 0で料金体系確認。高額なら自作MCP路線に戻る判断ポイントを設ける |
| `getObjectSchema` が日本語picklistを返さない | 中 | Phase 0で検証。不足ならCustom Serverに `getPicklistValues_ja` 追加 |
| `createSobjectRecord` でEmailMessage Draftが作れない | 中 | Phase 0で検証。NGならCustom Tool `createEmailDraft` 追加 |
| ListView作成がTooling APIで不可 | 中 | 代替: `Lead_Selection__c` 中間オブジェクト方式、または Custom Report |
| Queueable Callout の120秒タイムアウト | 低 | fire-and-forgetなのでQueueable側は数秒で終了、影響小 |
| Cloud Runコールドスタート | 中 | min-instances=1設定 |
| Long Text 131072 上限 | 低 | 応答分割送信 or Metadata__cに分割格納 |
| LLMの不正SOQL生成 | 高 | system promptで `getObjectSchema` 先行を徹底。エラー時retry |
| Anthropic/Gemini APIレート制限 | 低 | リトライ+exponential backoff |

---

## 11. 設計判断ログ

| 日付 | 判断 | 理由 |
|---|---|---|
| 2026-04-11 | Agentforce Topic/Actionは使わない | ユーザー動機が「Agentforceの構造的制約からの解放」。Topicに載せると制約を継承 |
| 2026-04-11 | MCPプロトコル採用 | 複数クライアント（Claude Desktop, LWC）で同一ツール定義を共有可能 |
| 2026-04-14 | LLM推論とAgent Runtimeを分離 | GPU VM不要。API LLMでデモ可、ローカルGemmaは将来オプション |
| 2026-04-14 | PoCはJWT Bearer、本番はPer-User OAuth | PoC速度優先 |
| 2026-04-15 | **自作MCPサーバー路線を破棄、Hosted MCP + Custom Server路線へ** | このorgで `McpServerDefinition` 等メタデータが既存、標準7サーバー38ツールが有効化可能、Per-User OAuth PKCE がネイティブ対応 |
| 2026-04-15 | **MuleSoft依存は誤認だった** | 「信頼関係」はAnypoint API Catalog連携用であり、標準サーバー有効化には不要 |
| 2026-04-15 | 既存Apex Invocable/Prompt Template資産をCustom Serverで再利用 | このorgにBOM分析・Account Insight等の資産が豊富に存在。McpServerToolApiDefinitionで紐付けるだけで再利用可能 |
| 2026-04-15 | 非同期パターン（Queueable + Platform Event）は維持 | Cloud Run側の処理時間に依存しないため、UX上有利 |

---

## 12. 未解決論点

### A. Hosted MCP の正式料金体系
2026-02 GA予定だったが、このorgでは既に使えそう。トライアル的な位置付けなのか、既に本格利用可能なのか要確認。

### B. Custom Server 有効化時の前提条件
`McpServerAccess` の `Active=true` にする前に必要な権限・設定は何か。External Client Appの作成が必要か。

### C. ListView作成の実現方法
キラーデモ最大の技術リスク。Tooling API経由か、中間オブジェクト方式か。Phase 0で判断。

### D. 図面解析モードとの統合
Gemma 4ローカルLLMを組み込むタイミング。Agent Runtime側でLLM切替済なので、Phase 4で差し替えるだけで良いはず。

### E. Agentforce（既存Topic）との併存方針
BOM_Analysis_Agentは継続稼働。Agentforce 2.0はユーティリティバー、Agentforceはレコードページパネル、と住み分け案。

### F. 本番運用時のSalesforce負荷
MCP経由のREST呼び出しがAPI制限（15,000/24h等）にどう影響するか。特に`soqlQuery`の乱発リスク。

---

## 13. 関連ドキュメント

- [コンセプト](../concepts/agentforce-2.0-concept.md)
- [Manufacturing Cloud 2.0 設計](../design/manufacturing-cloud-2.0-design.md)（BPSデモ既存設計）
- [Agentforceアーキテクチャガイド](../reference/agentforce-architecture-guide.md)（既存Agentforce実装）
- [gemma4-installプロジェクト](/Users/satoshi/claude/gemma4-install)（ローカルLLM検証資産）
