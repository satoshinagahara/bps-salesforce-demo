# Local Headless 360 設計書

> 作成日: 2026-04-14（大幅改訂: 2026-04-15）
> ステータス: 設計中
> コンセプト: [docs/concepts/lh360-concept.md](../concepts/lh360-concept.md)

---

## 改訂履歴

| 日付 | 変更内容 |
|---|---|
| 2026-04-14 | 初版作成。自作MCPサーバー10ツール前提で設計 |
| 2026-04-15 | **全面改訂**。Salesforce Hosted MCP (GA) の実態判明により、自作MCP路線から「標準MCP + Custom MCP + Agent Runtime」の4層構成に再設計。MuleSoft依存なし |
| 2026-04-18 | Phase 0 一部完了（Hosted MCP sobject-all + Claude Desktop 接続成功、動作検証済）。**ゴール再定義**: 「Salesforce を SSOT とした営業業務を、ローカルLLM + ローカルUIで効率的に回す」デモへ拡張。周辺データ（過去提案書・契約書等）、周辺アプリ（Gmail, Google Calendar）との連携も視野に入れる。ローカルLLMランタイム選択肢に **Microsoft Foundry Local** を追加（産業的エビデンス強化） |
| 2026-04-18 追加 | **Microsoft Foundry Local が Gemma 4 を正式対応（2026-04-14 公開）。戦略的位置付けを Secondary → Primary 候補へ格上げ検討**。公式チュートリアルに tool calling / voice-to-text / document summarizer が揃い、本デモのシナリオA/B/C 全てを Foundry Local 単独でカバー可能。Primary/Secondary の最終判定は実地ベンチ後に確定 |

---

## 1. ゴール

### 1.1 最終ビジョン（2026-04-18 再定義）

**Salesforce を SSOT（Single Source of Truth）とする営業業務を、ローカルLLM + ローカルアプリ（UI）で効率的に回すデモの構築。**

単なる「Agentforceの代替」ではなく、以下のメッセージを社内SE勉強会で実証する：

- **UI層はSalesforceを離れうる**（Claude Desktop, Gradio, Tauri, カスタムアプリ）
- **LLMは組織の外に依存しない**（ローカル実行、無料・機密保持）
- **だがデータの真実性・ガバナンス・アイデンティティ管理は Salesforce が担い続ける**
- **周辺データ（過去提案書、契約書、図面）・周辺アプリ（Gmail, Google Calendar, Drive）との連携**も同じ世界観で束ねる

→ 「SaaS is Dead議論」への具体的な回答: **「Salesforceの価値はUIではなく、data/governance/identity foundationに移る」** というテーゼの叩き台。

### 1.2 Local Headless 360 固有のゴール

Salesforce純正Agentforceの構造的制約（Topic境界、一問一答、状態なし）を超え、**自由対話・自律ツール選択・マルチターン深掘り**を Salesforce画面内（LWC薄チャット）**および** 外部クライアント（Claude Desktop / Gradio / Tauri等）から提供する。

### 1.3 達成条件（PoC）

キラーデモシナリオが通しで動作：

**シナリオA: リード自動化**
1. 自然言語での自由条件指定 → リード/商談の抽出
2. 「この10件でリストビュー作って」→ 作成
3. 「このリストにパーソナライズメール下書き作って」→ 複数件作成

**シナリオB: ドキュメント解釈**
4. 見込み顧客のWebサイト・過去提案書・業界レポートを束ねて「次の打ち手」を提案
5. 過去類似案件の提案書を参照して、現在案件用のドラフト生成

**シナリオC: 音声ロールプレイ（拡張）**
6. 製品紹介トークスクリプトの練習（音声入力→評価→フィードバック）

### 1.4 周辺連携（拡張スコープ）

| 連携先 | 目的 | 実装方法 |
|---|---|---|
| Gmail | メール下書き・送信・検索 | Gmail MCP / Google Workspace API |
| Google Calendar | 商談予定確認・会議設定 | Calendar MCP / Calendar API |
| Google Drive | 過去提案書・契約書の参照・RAG | Drive MCP / Drive API |
| ローカルファイル | デスクトップ上のCSV/PDFドロップ | UI側ファイルアップロード |
| Web検索 | 企業動向・業界ニュース | WebFetch系MCP |

Salesforce MCP で扱う一次情報（Account, Opportunity, BOM等）と、周辺MCPで扱う二次情報（メール履歴、カレンダー、ドキュメント）を**Agent Runtime上で統合**する構造。

### 1.5 副次目標（BPSデモ固有）

- Sales Agreement計画vs実績の乖離分析を自然対話で実行（Manufacturing Cloud 2.0との統合）
- 既存Apex Invocable資産（BOM分析、Account Insight等）を Local Headless 360 経由で呼び出し

---

## 2. アーキテクチャ：4層構成

### 2.1 全体図

```
┌─────────────── Layer 4: Salesforce UI ───────────────┐
│                                                        │
│  [LWC lh360Chat] ユーティリティバー配置         │
│   ├ チャット入力・表示                                 │
│   ├ ファイルドロップ（CSV/PDF対応）                    │
│   ├ レコードコンテキスト自動検出                       │
│   └ empApi: Platform Event subscribe                   │
│         │                                              │
│  [Apex: Lh360Service + Queueable]                │
│   └ Named Credential経由でAgent Runtimeへ非同期Callout │
│                                                        │
│  [Platform Event: Lh360_Response__e]             │
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
│   McpServerDefinition: bps-lh360-custom          │
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

| ツール名 | 機能 | Local Headless 360での用途 |
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
  DeveloperName: bps_lh360_custom
  MasterLabel: BPS Local Headless 360 Custom Tools
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
| ApiIdentifier | `Lh360_CreateListView` |
| 新規Apex | `Lh360CreateListView.cls`（InvocableMethod）|
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
        "event_name": "Lh360_Response__e"
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
        endpoint=f"{sf_instance}/services/data/v66.0/mcp/v1/custom/bps_lh360_custom",
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
# - local:   OpenAI互換ローカルサーバー（デフォルト、本案の主軸）
# - claude:  Anthropic SDK（対比デモ・緊急避難用）
# - gemini:  Google GenAI SDK（対比デモ用）
```

#### ローカルLLM接続仕様（本案の主軸）

| 項目 | 値 |
|---|---|
| プロトコル | OpenAI互換 REST (`/v1/chat/completions`) |
| エンドポイント | `http://127.0.0.1:8080/v1`（環境変数 `LOCAL_LLM_BASE_URL` で上書き可） |
| 現行実装 | **mlx-lm**（gemma4-installプロジェクト、M5 Mac上で稼働） |
| 将来候補 | Ollama（Metalバグ解消後に26B MoE想定）、vLLM（本番Linux/GPU想定） |
| モデル切替 | ランタイム起動時に選択（E4B: 開発時・軽量、**26B MoE: デモ本番・精度**） |
| Function Calling | 対応（mlx-lm側でJSONパーサーパッチ適用済、`MLX_STRIP_TOOLS=0` で有効化） |
| Streaming | **非対応**（UI側で応答完了までspinner表示、分割送信不要） |
| max_tokens | デフォルト4096、シナリオC（ロールプレイ）は8192推奨 |

#### 実装上の抽象化原則

- **「Gemma 4」や「mlx-lm」をコード内で直接参照しない**。OpenAI互換サーバーという抽象で扱う
- モデル名はAPIパラメータとして環境変数注入（`LOCAL_LLM_MODEL=gemma4-26b-moe-4bit`）
- ランタイム／推論エンジンが mlx-lm → Ollama → vLLM と変わっても、**Agent Runtime側のコード変更は不要**
- 切替コスト = `LOCAL_LLM_BASE_URL` と `LOCAL_LLM_MODEL` の環境変数更新のみ

#### ローカルLLMランタイム比較表（2026-04-18 更新版）

| ランタイム | 開発元 | Apple Silicon | Function Calling | Whisper統合 | Gemma 4対応 | OpenAI互換 | 備考 |
|---|---|---|---|---|---|---|---|
| **mlx-lm** | Apple ML Research | ◎ ネイティブMetal | ◯ `MLX_STRIP_TOOLS=0` | ✕（別途mlx-whisper） | ◎ 26B MoE動作確認済 | ◎（自前起動）| 最速性能、自己責任運用 |
| **Microsoft Foundry Local** | Microsoft | ◯（Apple Silicon明示対応、ONNX Runtime）| ◎ 公式チュートリアルあり | ◎ 同カタログ、公式voice-to-textチュートリアル | **◎ E2B/E4B/26B A4B/31B（2026-04-14対応）** | ◎ 標準装備 | **Microsoft公式 × Google Gemma の構図**、SDK複数言語、active 開発、CLI/REST/SDK揃う |
| **Ollama** | Ollama Inc | △ macOS 15でMetalバグ（当org環境）| ◯ | ✕ | ◎ | ◎ | Metalバグ解消待ち |
| **llama.cpp** | ggerganov | ◯ | ◯ | ✕ | ◎ | ◎ | Ollamaより低レベル |
| **vLLM** | UC Berkeley | ✕（CUDA前提）| ◎ | ✕ | ◎ | ◎ | 本番Linux/GPU想定 |

#### 大きな地殻変動: Foundry Local の Gemma 4 対応（2026-04-14）

従来の評価では「Foundry Local は Gemma 4 非対応」が最大のハンデだったが、**2026-04-14 に正式対応**。これにより：

- Gemma 4 の全バリアント（E2B / E4B / 26B A4B / 31B）が Foundry Local カタログに入る
- **公式チュートリアル**が本デモのシナリオ全てに対応：
  - `tutorial-build-tool-calling-assistant` → **シナリオA**（MCP連携）
  - `tutorial-build-voice-to-text-note-taker` → **シナリオC**（音声ロールプレイ）
  - `tutorial-build-document-summarizer` → **シナリオB**（ドキュメント解釈）
  - `tutorial-build-chat-assistant` → 基本会話
- LangChain統合も公式How-toあり

#### 勉強会テーゼへの影響

Foundry Local + Gemma 4 の組合せは、勉強会テーゼ「AI がローカル・産業トレンド化する世界」を**2大ベンダの組合せとして**語れる材料となる：

- **Microsoft公式** が on-device AI SDK を本格推進
- そのカタログに **Google DeepMind 製 Gemma 4** が入る
- Whisper 同カタログで音声AIローカル完結
- Tool Calling 公式チュートリアル化（= プロダクション品質の on-device Agent が射程に）

「on-device AIは個人プロジェクトではない、2大ベンダーが本気で張っている産業トレンド」というナラティブが直接成立する。

#### ランタイム採用方針（要再評価・実地検証予定）

**旧方針**（2026-04-16 決定）: mlx-lm Primary、Foundry Local Secondary  
**新方針候補**（実地ベンチ後確定）:

| 案 | 内容 | 採用条件 |
|---|---|---|
| **案A**: Foundry Local Primary | Foundry Local + Gemma 4 26B を主軸。mlx-lm は比較用に残す | Foundry Localの性能がmlx-lm比80%以上、安定性問題なし |
| **案B**: Dual Primary | 両者を同格で並走、シナリオ毎に使い分け | 性能差明確、特性が補完的 |
| **案C**: mlx-lm Primary 継続 | 現状維持、Foundry Local はSecondaryで産業エビデンス用のみ | Foundry Localの性能が大幅劣後、または macOS で不安定 |

**判定方法**: 
1. Foundry Local を実機インストール → Gemma 4 E4B で tool calling テスト
2. 性能ベンチ（tok/s、first token latency、tool call round-trip時間）
3. 26B A4B でも同様にベンチ
4. mlx-lm の既存ベンチと比較

実地検証は**2026-04-18 本日実施予定**。結果に基づいて案A/B/Cを確定し、本設計書 Section 11 に設計判断ログとして記録する。

#### 将来的な位置付け

- **将来復帰候補**: Ollama（Metalバグ解消時）
- **本番想定**: vLLM on Linux GPU（顧客環境デプロイ時）
- いずれも OpenAI互換API 抽象を経由するため、切替コストは環境変数のみ

---

## 6. Layer 4: Salesforce UI

### 6.1 LWC: lh360Chat

**配置**: ユーティリティバー（全画面共通）+ 必要に応じてレコードページにも

```
lh360Chat/
  ├ lh360Chat.html
  ├ lh360Chat.js
  ├ lh360Chat.css
  └ lh360Chat.js-meta.xml
```

**主要機能**:
- テキスト入力 + 送信ボタン
- ファイルドロップ（CSV/PDF対応）
- メッセージ表示（user / assistant、Markdownレンダリング）
- 「思考中...」インジケータ
- `empApi` による `Lh360_Response__e` subscribe
- レコードページ配置時は `@api recordId` で自動コンテキスト取得
- セッションID生成（`crypto.randomUUID()`相当）
- ページ遷移時にセッションリセット

**状態**:
- LWCは表示用キャッシュのみ
- 真の会話履歴はAgent Runtime側

### 6.2 Apex層

#### Lh360Service.cls (@AuraEnabled)

```apex
public class Lh360Service {

    @AuraEnabled
    public static String sendMessage(String sessionId, String message,
                                      String recordId, String objectApiName,
                                      List<Map<String,String>> attachments) {
        Lh360Callout job = new Lh360Callout(
            sessionId, message, recordId, objectApiName,
            UserInfo.getUserId(), attachments
        );
        Id jobId = System.enqueueJob(job);
        return jobId;
    }
}
```

#### Lh360Callout.cls (Queueable + AllowsCallouts)

Named Credential経由でAgent Runtimeに非同期POST。同期Calloutしたら即時終了（Agent側の処理完了を待たない）。応答はPlatform Event経由で非同期受信。

### 6.3 Platform Event: Lh360_Response__e

| フィールド | 型 | 説明 |
|---|---|---|
| Session_Id__c | Text(100) | LWCセッションIDと一致 |
| Message__c | Long Text(131072) | 応答（Markdown）|
| Status__c | Text(20) | `streaming` / `complete` / `error` |
| Metadata__c | Long Text(32768) | ツール実行サマリ等のJSON |

Agent RuntimeがSalesforce REST API経由でPublish：

```python
async def publish_platform_event(token, instance, session_id, message, status):
    url = f"{instance}/services/data/v66.0/sobjects/Lh360_Response__e"
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
| Label | Lh360 Runtime |
| Name | Lh360_Runtime |
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
[Apex Lh360Service]
  │ (2) Queueable enqueue → jobId返却
  │     LWCはローディング表示
  ▼
[Queueable Lh360Callout]
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
  │ (6) Lh360_Response__e 発火
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

- [ ] `McpServerDefinition: bps_lh360_custom` 作成
- [ ] 新規Apex `Lh360CreateListView` 実装（ListView補完）
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

- [ ] Platform Event `Lh360_Response__e` 作成
- [ ] Apex `Lh360Service` + `Lh360Callout` 実装
- [ ] Named Credential設定
- [ ] LWC `lh360Chat` 実装
- [ ] ユーティリティバー配置
- [ ] キラーデモ通し試験

**成果物**: Salesforce内で動くLocal Headless 360

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
| 2026-04-16 | LLMは**ローカルLLM（Gemma 4）を主軸**。Claude/Geminiは対比・緊急避難用 | 勉強会テーゼ「AIがローカル・実質無料化する世界」の実証には、デモ自体がローカルLLMで動作することが必須 |
| 2026-04-16 | 推論エンジンは **mlx-lm** から開始、将来Ollama 26B MoEへ | 現在M5 Mac/macOS 15のMetalバグでOllama不可。mlx-lmで即座に稼働可能。OpenAI互換プロトコルで抽象化しているため、Ollama復帰時は環境変数変更のみで切替可能 |
| 2026-04-18 | **デモゴールを「Salesforce SSOT + ローカルLLM + ローカルUI + 周辺アプリ連携」に拡張** | 社内SE勉強会の真のメッセージは「Salesforceの価値はUIではなく、data/governance/identity foundationに移る」。Salesforce単体のAgent置換に留めず、Gmail/Calendar/Drive等との統合まで視野に入れることで、SSOT論を強化する |
| 2026-04-18 | **ローカルLLMランタイムの第2選択肢として Microsoft Foundry Local を採用候補に追加** | Microsoft公式がon-device AI SDK（ONNX Runtime ベース、macOS対応、OpenAI互換、Whisper同梱）をactiveに推進中。「ローカルAIへのシフトは産業トレンド」という勉強会論拠の補強材料。Gemma 4カタログ非対応のため mlx-lm を置換はせず、比較用セカンダリとして位置付け |
| 2026-04-18 改訂 | **Foundry Local の Gemma 4 対応（2026-04-14）判明により、Primary/Secondary 判定を保留・要実機検証に変更** | 従来Secondaryに据えた最大の根拠「Gemma 4非対応」が解消。公式チュートリアルでシナリオA/B/C 全てをカバー可能。Microsoft公式 × Google Gemma の構図が勉強会テーゼを大幅に強化。本日中にFoundry Local実機ベンチを実施し、案A（Foundry Local Primary）/ 案B（Dual Primary）/ 案C（mlx-lm Primary継続）から確定 |
| 2026-04-18 | **Hosted MCP sobject-all の動作検証完了（Phase 0 部分完了）** | Claude Desktopから日本語クエリ、スキーマ取得、レコード更新まで動作確認済。特に `getObjectSchema` が日本語picklist値を返すこと、複数マッチ時のインタラクティブ選択UI、更新後のSOQL再検証挙動を確認。Phase 1 以降の実装前提が確定した |
| 2026-04-18 実測 | **Foundry Local の Gemma 4 macOS カタログ非搭載を実機確認**（Microsoft 2026-04-14 ブログは Azure AI Foundry クラウド側の話と推定） | `foundry model list` と `/foundry/list` REST で 24 aliases 全取得（Qwen2.5/3、Phi-3/3.5/4、DeepSeek R1、Mistral、gpt-oss-20b、Whisper系）。Gemma 系は0件。Azure AI Foundry（クラウド）と Foundry Local（オンデバイス ONNX）はカタログが別管理。Foundry Local の戦略的位置付けを **Secondary に戻す**。ただし Microsoft公式 × OpenAI互換 × Whisper同梱 × tool calling対応（qwen2.5系）の構図は勉強会テーゼ補強として依然有効 |
| 2026-04-18 実測 | **Foundry Local での tool calling 疎通確認（qwen2.5-1.5b-GPU）** | OpenAI互換 `/v1/chat/completions` で `tool_choice=auto`、WebGPU（macOS Metal経由）で chat 0.89s / tool call 0.87s、`finish_reason=tool_calls` で structured JSON `{"soql":"SELECT COUNT(Id) FROM Lead"}` を正しく返却。知識精度は1.5Bの限界で「SSOT」を「Single Sign-On Token」と誤認識。営業語彙の精度担保には phi-4-mini (3.72GB GPU) または 7B以上が必要。qwen3-0.6b (CPU) は reasoning content を返し structured tool_calls を出さず→ tool calling 用途には qwen2.5系 or phi-4-mini を採用 |
| 2026-04-18 判定 | **ランタイム最終案: 案C（mlx-lm Primary 継続、Foundry Local Secondary）** | Gemma 4 が macOS Foundry Local 非搭載の事実が確定したため。Primaryに据える根拠（Gemma 4使える）が消失。mlx-lm は既に動作実績あり、Gemma 4 MLX対応が先行している。Foundry Local は Phase 2以降で「Microsoft陣営のローカルAI推進」文脈の補助デモとして紹介（Whisper音声ノート等、Phase 3で活用検討） |
| 2026-04-18 確定 | **Foundry Local は今回のデモ作業スコープから一旦除外（Whisper音声ノート用途含む）** | macOS Foundry Local のモデル陣（2024年末までのPhi/Qwen2.5、Qwen3は0.6bのみ、Gemma/Llama無し）は、2026年最新世代の Gemma 4 系（E4B/26B A4B/31B 256K）と比較して **明確に見劣り**。"Microsoft公式 on-device AI" の物語的価値だけではデモのPrimary/Secondary両方から外す判断。Phase 1 本丸は **mlx-lm + Gemma 4 + Gradio UI** で進める。※Foundry Local 自体のインストール・検証手順・tool calling動作確認は完了済（将来再開時の初期コストゼロ） |
| 2026-04-18 宿題 | **Foundry Local macOSカタログ拡充の再評価トリガーを設定** | Gemma 4 が業界で強くバズっている状況と、Azure AI Foundry（クラウド）側では既に対応している事実から、Microsoft が macOS Foundry Local でも Gemma 4 / Llama 4 系を追加するのは時間の問題と推定。再評価トリガー: ①Microsoft公式ブログで "Foundry Local" キーワードと Gemma/Llama 追加アナウンス、②`foundry model list` でGemma系alias出現、③公式サンプルにmacOSベンチ登場、のいずれか。その時点で Secondary 位置付け（Whisper音声ノート Phase 3、比較デモ用途）で再検討 |

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
BOM_Analysis_Agentは継続稼働。Local Headless 360はユーティリティバー、Agentforceはレコードページパネル、と住み分け案。

### F. 本番運用時のSalesforce負荷
MCP経由のREST呼び出しがAPI制限（15,000/24h等）にどう影響するか。特に`soqlQuery`の乱発リスク。

### G. 周辺アプリ連携のMCP構成

Gmail / Google Calendar / Google Drive との連携を Agent Runtime から束ねる際、以下3パターンを比較する。

#### G.1 構成パターンの図解

```
パターン①: Agent Runtime集約型
[UI] ── [Agent Runtime] ── MCP ─┬─> Salesforce MCP
                                  ├─> Gmail MCP
                                  ├─> Calendar MCP
                                  └─> Drive MCP

パターン②: UIアプリ集約型
[UI (Claude Desktop / Gradio)] ── MCP ─┬─> Salesforce MCP
                                         ├─> Gmail MCP
                                         ├─> Calendar MCP
                                         └─> Drive MCP
(Agent Runtime は UI 内蔵 or 軽量な Salesforce 特化レイヤに限定)

パターン③: 独自統合Tool層
[UI] ── [Agent Runtime + 独自Tool群] ── 直接API ─┬─> Salesforce REST
                                                    ├─> Gmail API
                                                    ├─> Calendar API
                                                    └─> Drive API
(MCPは使わない or Salesforce MCPのみ使う)
```

#### G.2 技術比較

| 観点 | ① Agent Runtime集約 | ② UIアプリ集約 | ③ 独自統合Tool層 |
|---|---|---|---|
| **MCP思想整合** | ◎ 純粋なMCP構成 | ◎ 純粋 | × MCPを捨てる |
| **UIの交換容易性** | ◎ 複数UI可能 | △ UI毎に全MCP接続必要 | ◯ |
| **認証情報の配置** | Runtime側に集中（Google OAuth tokenは Runtime環境変数 or Secret Manager）| UI側（Claude Desktop 等が各MCPのOAuthを個別管理）| Runtime側 + 独自管理 |
| **ユーザー毎OAuth** | △ Runtime共有の場合マルチテナント設計必要 | ◎ UIがユーザー個別起動なので自然にPer-User | △ 自前実装 |
| **秘匿情報の流出面** | Runtime server を 1点狙われうる | UI端末個別（分散リスク）| 同① |
| **監査ログ** | Runtime一元 | MCP毎ログ分散 | Runtime一元 |
| **レイテンシ** | ◯ Runtimeが近隣クラウド | ◎ 全てローカル | ◯ |
| **開発複雑度** | 中（MCP Client多接続管理）| 小（UIアプリが既存MCPクライアント機能を使う）| 大（各API個別実装）|
| **ローカル完結度** | × Runtimeがクラウドなら部分的 | ◎ 全てローカルで完結 | × |
| **スケーラビリティ** | ◎ Runtime追加でスケール | × UI端末毎 | ◎ |
| **勉強会テーゼ整合** | ◯「ローカルUI + クラウドRuntime」の形 | ◎「ローカル完結」を最大限示せる | × MCPの思想を殺すため使わない |

#### G.3 セキュリティ詳細

**パターン①の課題**:
- Agent Runtime（Cloud Run）が Gmail / Drive の OAuth refresh token を保持する必要
- マルチテナントにする場合、ユーザー毎の token を安全に管理（Secret Manager + KMS暗号化等）
- Runtime が侵害されると全ユーザーのGoogleアカウントにアクセス可能な最悪シナリオ
- **緩和策**: Per-User OAuth をリアルタイムでリフレッシュし、Runtime側にはaccess tokenのみ短期保持

**パターン②の課題**:
- 各UI端末に Google OAuth token が保存（OS Keychain等）
- 紛失・マルウェア感染時、当該ユーザーのみ影響（**攻撃面が分散するのは利点**）
- MCP client仕様上、各MCPサーバーへの認証は独立（1つのSSOでまとめにくい）
- **緩和策**: UI側でOS-levelキー管理（Keychain / Credential Manager）を使う

**パターン③の課題**:
- MCP仕様から外れるため、他UIアプリからの再利用不可
- Google API の認証・レート制限・エラー処理を全部自前で書く
- **採用根拠が薄い**: MCPが既にあるのに捨てる合理性が乏しい

#### G.4 本デモでの推奨

| フェーズ | 推奨パターン | 理由 |
|---|---|---|
| Phase 1（Salesforce単体）| パターン② Gradio内にMCP Client内蔵 | ローカル完結。構成シンプル |
| Phase 2（周辺連携追加）| **パターン② 継続** | 勉強会テーゼ「ローカル完結」に最も整合。Gradio側で複数MCP統合 |
| Phase 4（LWC統合版）| パターン①（ハイブリッド）| LWC はRuntimeに投げるしかないため、Runtime側で各MCP接続。ただし主軸はパターン②で、これは「LWC版もある」という補助的位置付け |

**結論**: **パターン②を主軸、パターン①は Phase 4 LWC版でのみ採用。パターン③は不採用。**

#### G.5 認証アーキテクチャ（パターン②採用時）

```
[Gradio ローカルアプリ]
  │
  ├─ [MCP Client A] ─OAuth 2.0 PKCE─> Salesforce Hosted MCP
  │                                    (token保管: Keychain)
  │
  ├─ [MCP Client B] ─OAuth 2.0───────> Gmail MCP Server
  │                                    (token保管: Keychain)
  │
  ├─ [MCP Client C] ─OAuth 2.0───────> Calendar MCP Server
  │                                    (token保管: Keychain)
  │
  └─ [MCP Client D] ─OAuth 2.0───────> Drive MCP Server
                                       (token保管: Keychain)
```

- 各MCPサーバーとの認証は独立（MCP仕様通り）
- token はOS Keychain（macOS）/ Credential Manager（Windows）で保管
- Gradioアプリ起動時に各接続状態を一覧表示
- 未接続のMCPがあればConnect UIを提示

**ただし**: Claude Desktop は既にこの機構を持つ。Gradio側で同等機能を自作する代わりに、**Phase 2 では一旦 Claude Desktop を UI として使い続ける選択肢**もある（開発コスト削減）。Gradio独自UIが必要な Phase 3（音声）以降で自作に移行。

### H. 過去ドキュメントのRAG戦略
過去提案書・契約書・図面を LLMコンテキストに載せる方法：
- **A案**: Salesforce Data Cloud の既存Vector Search（このorgで構築済）を Custom MCP Tool 経由で呼ぶ
- **B案**: ローカル側（Agent Runtime or UI）にChroma/Qdrant等を立てる
- **C案**: Google Drive MCP で都度検索（都度RAG）

SSOT論を貫くならA案が最も整合的。B/C案は「ローカル完結」論と整合するが、SSOT論との緊張関係がある。勉強会のテーゼとして**「Salesforce Data CloudをRAGのSSOT基盤として位置付ける」**のが有力。

---

## 13. 関連ドキュメント

- [コンセプト](../concepts/lh360-concept.md)
- [Manufacturing Cloud 2.0 設計](../design/manufacturing-cloud-2.0-design.md)（BPSデモ既存設計）
- [Agentforceアーキテクチャガイド](../reference/agentforce-architecture-guide.md)（既存Agentforce実装）
- [gemma4-installプロジェクト](/Users/satoshi/claude/gemma4-install)（ローカルLLM検証資産）
