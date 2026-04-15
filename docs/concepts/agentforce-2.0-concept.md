# Agentforce 2.0 構想

> 作成日: 2026-04-11（更新: 2026-04-14）
> ステータス: コンセプト → 設計着手
> 設計書: [docs/in-progress/agentforce-2.0-design.md](../in-progress/agentforce-2.0-design.md)
> 関連: [Manufacturing Cloud 2.0](../design/manufacturing-cloud-2.0-design.md)（Salesforce純正に対するカスタム拡張という同種の発想）

---

## 1. コンセプト

**Salesforce純正のAgentforceでは原理的に到達できない「自由対話・自律ツール選択・マルチターン深掘り」を、外部LLM Agent + 自作Salesforce MCPで実現する。**

Manufacturing Cloud 2.0が「Salesforce純正Manufacturing Cloudに似て非なる、業務密着の付加価値カスタム実装」だったのと同じ発想で、Agentforceに対する似て非なるカスタム実装を目指す。両者は競合せず、用途で棲み分ける。

---

## 2. 出発点となった問題意識

このorgではAgentforce（BOM_Analysis_Agent等）を実装・運用してきた経験から、以下の構造的制約が明らかになった：

| Agentforceの制約 | 実例 |
|---|---|
| Topic境界が固い | 「商談分析中にこの会社の最新ニュースも調べて」のような横断ができない |
| Action入力は型付きパラメータ | 「従業員500人以上、関東エリア」のような自由文条件をSOQLに変換できない |
| 状態を持たない | 1ターン目の結果を2ターン目で「この10件」と参照できない |
| ループ的処理ができない | 「10件それぞれにメール下書きを作成」が原理的に不可能 |
| 一問一答に近い | 同一セッション内のAction再実行も裏技（`userQuery`渡し）でしか実現できない |
| LLM選択制約 | Atlas / BYO-LLMの範囲内 |
| プロンプト管理 | Prompt Builder UIに閉じ、git管理しづらい |

**これらは「Agentforceがプラットフォームのセキュリティと監査を継承するために選んだ設計上のトレードオフ」**であり、Agentforce自体の出来が悪いわけではない。ただし、自由度を求めるユースケースには合わない。

---

## 3. 解決アプローチ

### 基本方針

- **頭脳は外部**: Agent Runtime（LLM + ツール選択ループ）はSalesforce外で動かす
- **LLM推論とAgent Runtimeは分離**: Agent Runtime + MCPサーバーはCPU-onlyの軽量プロセス。LLMは差し替え可能（API LLM or ローカルLLM）
- **Salesforceは器**: System of Record + 認可基盤として使う
- **MCPが契約**: 両者の間はMCP（Model Context Protocol）で接続
- **権限はネイティブ継承**: Per-User OAuthで各ユーザーのRunning Userコンテキストを保ち、FLS・共有ルールを完全に効かせる

### Agentforceとの棲み分け

| 用途 | Agentforce | Agentforce 2.0（本構想） |
|---|---|---|
| レコード単位の定型分析 | ◎ | ○ |
| 業務ワークフロー連動 | ◎ | △ |
| Service Cloudの顧客対応チャット | ◎ | × |
| 自由対話・深掘り | × | ◎ |
| マルチターン横断アクション | × | ◎ |
| ツール選択の自律性 | × | ◎ |
| 外部データ・外部LLM統合 | △ | ◎ |
| 自社管理LLM（オンプレ要件） | × | ◎ |
| 開発体験（コード中心、テスト容易）| △ | ◎ |

両者は競合せず併存する。

---

## 4. アーキテクチャ

### 全体構成

**重要な設計判断（2026-04-14追記）: LLM推論とAgent Runtimeの分離**

Agent Runtime + MCPサーバーはCPU-onlyの軽量プロセスであり、GPU VMは不要。LLM推論はAPI呼び出し（Claude API / Gemini API）で賄い、ローカルLLM（Gemma 4）はデータ主権が要件となる場合のオプション。

```
[ユーザー]
   │
   ▼
┌─────────────── Salesforce Org ──────────────┐
│ [LWC 薄チャットクライアント]                 │
│  ├ メッセージ送受信のみ                      │
│  ├ ファイルドロップ                          │
│  ├ レコードコンテキスト送出                  │
│  └ Apex Callout / Platform Event subscribe   │
└──────────────────┬───────────────────────────┘
                   │ HTTPS
                   │ Per-User Named Credential
                   │ (各ユーザーのOAuth token)
                   ▼
┌─────────────── 外部サーバー ─────────────────┐
│ [Agent Runtime]  (CPU-only, 軽量)            │
│  ├ 会話履歴保持（Redis / インメモリ）        │
│  ├ Agent Loop (ReAct or function calling)    │
│  └ MCPクライアント                           │
│        │                                     │
│        ├─▶ [Salesforce MCP Server]            │
│        │    全ツール常時利用可能              │
│        │    受け取ったuser tokenでREST API    │
│        │        │                             │
│        │        ▼                             │
│        │   [Salesforce Org]                   │
│        │                                     │
│        └─▶ [LLM 推論] ※差し替え可能          │
│             ├ Claude API (デモ・標準)         │
│             ├ Gemini API (GCP連携時)          │
│             └ Gemma 4 mlx-lm (オンプレ要件)  │
└──────────────────────────────────────────────┘
```

**デプロイコスト比較:**

| 構成 | 月額目安 | 用途 |
|---|---|---|
| Cloud Run + Claude API | $5〜30 | デモ・標準運用 |
| Cloud Run + Gemini API | $5〜20 | GCPエコシステム内運用 |
| ローカルMac + Gemma 4 | 電気代のみ | 開発・オンプレ要件 |
| GPU VM + Gemma 4 | $600〜750/月 | 本番スケール（データ主権）|

### 設計上の3つの肝

#### (1) 状態と自律はLLMが自然に持つ

汎用LLMのAgent Loopは、会話履歴とtool結果をすべてコンテキスト上に保持する。「この10件」「さっきのリスト」のような参照は実装不要で成立する。

- 会話履歴 → コンテキスト
- Tool結果 → コンテキスト
- 次のtool選択 → LLMが自律判断
- ループ処理 → LLMがfor文相当を発行

Agentforceがわざわざ砕いている「自然な性質」を、そのまま活用する。

#### (2) Per-User OAuth による権限継承

| 方式 | 評価 |
|---|---|
| **Per-User Named Credential (OAuth)** ★本命 | Apex Calloutが各ユーザーのOAuth tokenを自動付与。VM側MCPはそのtokenでSalesforce REST呼び出し。FLS・共有ルール・監査全てネイティブで動作 |
| Session ID転送 | 一部REST APIで制限。監査追跡も劣化。非推奨 |
| Integration User 1本 | 全ユーザー分を1ユーザーで代行。権限継承不可、誰の操作か追跡不可。デモ限定 |

#### (3) LWCは「皮」、状態と知能は外部

- LWC側にロジックを持たせない（Apex Action / Topic / Prompt Templateは一切使わない）
- 会話履歴・コンテキスト・ツール選択ロジックは全て外部VM側
- LWCは表示用のキャッシュのみ

---

## 5. キラーデモシナリオ

「Agentforceからの解放」を最も明確に示すのは、図面解析よりも以下の**マルチターン横断フロー**である。

### シナリオ: リード抽出 → リストビュー化 → パーソナライズメール

```
User: "従業員500人以上、業種が半導体製造装置、関東エリアのリードを抽出して"

Agent: [tool] sobject_describe('Lead')
       [tool] picklist_values('Lead', 'Industry')   ← 日本語値を確認
       [tool] soql_query("SELECT Id, Name, Company, Industry, NumberOfEmployees, State
                          FROM Lead
                          WHERE NumberOfEmployees >= 500
                            AND Industry = '半導体製造装置'
                            AND State IN ('東京都','神奈川県','埼玉県','千葉県')")
       → 23件
       表示: "23件見つかりました..."

User: "この中で従業員数上位10件に絞って、私専用のリストビューとして
       『半導体_注力リード』を作って"

Agent: [tool] listview_create(
                sobject='Lead',
                name='半導体_注力リード',
                scope='Mine',
                filters=[{field:'Id', op:'IN', value:[10件のID]}])
       表示: "作りました → [リンク]"

User: "完璧。この10社それぞれに、当社の○○製品を紹介する
       メール下書きを作って。会社名と過去の取引実績があれば
       それも踏まえてパーソナライズして"

Agent: [思考] 10件をループ
       [tool] (各社について) soql_query で過去Account/Opportunity実績取得
       [tool] (各社について) LLM自身でメール本文生成
       [tool] (各社について) email_draft(to_id, subject, body)
       表示: "10件の下書きを作成しました
              1社目: ○○株式会社 → [リンク]
              ..."
```

このフローはAgentforceでは原理的に不可能である：
- Step 1: 自由文SOQL条件 → 不可
- Step 2: 「この10件」の状態参照 → 不可
- Step 3: 動的フィルタを持つListView動的生成 → 不可
- Step 3→4: Topic境界を越える → 不可
- Step 4: 10件ループ + 各社個別生成 → 不可

逆に、汎用LLM + Agent Loop + MCPであれば、追加実装ゼロで自然に動作する。

### サブシナリオ: 図面解析 → Opportunity起票

製造業向けユースケースとしての副次デモ。Gemma 4のマルチモーダル能力を活かす。詳細は別途検討。

- ユーザーが図面PDFをチャットにドロップ
- Gemma 4が解析し構造化JSONを抽出
- 類似商談をMCP経由でSOQL検索
- Opportunity + LineItemを自動起票（承認後）
- 既存知見: [gemma4-installプロジェクト](/Users/satoshi/claude/gemma4-install)でGemma 4 26B + mlx-lmにより製造図面Level 3まで実用精度を確認済

---

## 6. 必要なMCPツール（最小セット）

10ツール程度でキラーデモは成立する。

| カテゴリ | ツール | 用途 |
|---|---|---|
| クエリ | `soql_query` | **自由文SOQL**（テンプレート化はNG）|
| | `sosl_search` | 横断検索 |
| | `sobject_describe` | スキーマ自己発見 |
| | `picklist_values` | 日本語選択リスト値の正確な取得 |
| 書き込み | `record_create` | 汎用INSERT |
| | `record_update` | 汎用UPDATE |
| | `record_delete` | 汎用DELETE |
| リストビュー | `listview_create` | Tooling APIのListView SObject経由 |
| メール | `email_draft` | EmailMessage Draft作成 |
| ユーザー | `current_user` | UserInfo取得 |

将来拡張: `apex_invoke`, `flow_run`, `file_read`, `file_upload`（図面用）, `connectapi_promptcall`（Salesforceマルチモーダル併用時）等。

---

## 7. クライアント側の選択肢（同一バックエンドへの複数フロントエンド）

MCPの真価は再利用性。同じMCPサーバーに対して複数のクライアントが接続できる。

| クライアント | 用途 | 実装の重さ |
|---|---|---|
| **Claude Desktop / Code** | 管理者作業、PoC初期、社員のパワーユーザー | ゼロ（既存）|
| **LWC薄チャット** | Salesforceに常駐する一般ユーザー | 中 |
| **専用Webアプリ** | UIの自由度が必要な企画担当等 | 中〜大 |
| **Local Jan等** | 個人検証 | 小 |

PoC初期は Claude Desktop だけで十分、後段で必要に応じて追加する。

---

## 8. デプロイ戦略

### 標準構成（デモ・一般用途）: Cloud Run + API LLM

GPU VM不要。Agent Runtime + MCPサーバーはCPU-onlyコンテナで動く。LLM推論はAPI呼び出し。

| コンポーネント | 配置先 | コスト |
|---|---|---|
| Agent Runtime + MCP | GCP Cloud Run | $0〜10/月（従量課金）|
| LLM推論 | Claude API / Gemini API | $数〜数十/月（利用量次第）|
| 会話履歴 | Cloud Memorystore (Redis) or インメモリ | $0〜15/月 |

**合計: $5〜30/月** でデモ環境として十分。

### オンプレ構成（データ主権要件）: Mac Studio + Gemma 4

製造業の図面データ等、社外に出せない機密データを扱う場合：

| 選択肢 | 初期コスト | 月額 |
|---|---|---|
| **Mac Mini / Mac Studio (M-series)** | 15〜30万円 | 電気代のみ |
| AWS EC2 g5.xlarge (GPU) | — | ~$750/月 |
| オンプレLinux + GPU | 50〜100万円 | 電気代のみ |

### 開発構成: ローカルMac

既存のmlx-lm環境（gemma4-installプロジェクト）をそのまま使う。追加コストゼロ。

---

## 9. ロードマップ（最短経路）

### Week 1: MCPサーバー最小実装
- Connected App作成（OAuth Web Server Flow）
- Python製MCPサーバー（10ツール、simple-salesforce or jsforce相当）
- Claude Desktopから接続疎通
- **この時点で管理者作業が即座に楽になる**（私の作業効率改善という即時メリット）

### Week 2-3: キラーデモシナリオの磨き込み
- リード抽出 → ListView → メールフローを通しで動作
- エラーケース対応、ツール追加
- ListView動的生成、EmailMessage Draft作成の実装精緻化

### Week 4-5: LWC薄チャットクライアント
- Salesforce画面内で使えるLWCチャットUI
- Apex Callout → Cloud Run（Agent Runtime）
- Platform Eventで非同期応答
- レコードコンテキスト自動連携

### Week 6-: 拡張
- Gemma 4への差し替え（オンプレ要件向け）
- 図面解析モード追加（マルチモーダル）
- Per-User OAuth Named Credential本格設定

### 最初に実装すべきこと
- [ ] Connected App作成（OAuth scope: api, refresh_token, offline_access）
- [ ] PythonでMCPサーバー雛形（mcp-python-sdk）
- [ ] simple-salesforceでSalesforce REST/Tooling API接続
- [ ] 10ツールの実装
- [ ] Claude Desktopのconfig.jsonに登録
- [ ] キラーデモシナリオを Claude Desktop で実施

---

## 10. 未解決論点

### A. MCPサーバーの実行場所
PoC初期は私のローカルMacでよいか、最初から共有VMに置くか。Mac Mini想定なら最初からそこに置く方が手戻りなし。

### B. ListView動的生成の現実性
Tooling APIの`ListView` SObjectで作成可能だが、フィルタにIN句で大量IDを指定したときの上限・パフォーマンスは要検証。代替案: Custom Object `Lead_Selection__c` でIDセットを保持し、List ViewはそのCustom Objectのフィルタにする。

### C. EmailMessage Draftの送信権限
Draft作成だけならEmailMessage作成権限で足りるが、最終送信はEmail Service or sendEmail() Apex呼び出しが必要。送信導線をどう設計するか。

### D. PoC段階の認可
Per-User Named Credentialは本来Salesforce Admin設定が必要。PoC初期はIntegration Userで進めるか、最初からPer-Userで組むか。後者の方が手戻りが少ない。

### E. キラーデモの「業務的な意味」付け
「リード抽出→リストビュー→メール」はAI能力デモとしては強いが、BPSの実業務文脈との接続を持たせると更に説得力が出る。例: 「特定の品質課題を持つ顧客群を抽出 → 改善提案メールを作成」等。

### F. Agentforceとの併存方針
両者を併存させる場合のUI誘導をどうするか。LWCとAgentforceチャットパネルが同一画面に並ぶ形になる。ユーザー混乱を避ける説明が必要。

---

## 11. 関連ドキュメント

- [gemma4-installプロジェクト](/Users/satoshi/claude/gemma4-install) - ローカルLLM検証の基盤資産
- [Manufacturing Cloud 2.0](../design/manufacturing-cloud-2.0-design.md) - 同種の「純正に対するカスタム拡張」発想
- [Agentforce アーキテクチャガイド](../reference/agentforce-architecture-guide.md) - 既存Agentforce運用方針
- [Agentforceサーベイ](./agentforce-survey-deep-dive.md) - Agentforce深掘り調査
