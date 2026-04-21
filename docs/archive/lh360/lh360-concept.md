# Local Headless 360 構想

> 作成日: 2026-04-11（更新: 2026-04-18）
> ステータス: コンセプト → 設計着手 → Phase 0 部分完了（Hosted MCP + Claude Desktop 動作確認済）
> 設計書: [lh360-design.md](./lh360-design.md)
> 関連: [Manufacturing Cloud 2.0](../design/manufacturing-cloud-2.0-design.md)（Salesforce純正に対するカスタム拡張という同種の発想）

---

## 改訂履歴

| 日付 | 変更 |
|---|---|
| 2026-04-11 | 初版。Agentforceの構造的制約からの解放を主題に自作MCP + 外部LLM構想 |
| 2026-04-14 | LLM推論とAgent Runtimeの分離、Cloud Run + API LLMによる低コスト構成を追加 |
| 2026-04-15 | Salesforce Hosted MCP (GA) を前提に「4層構成」へ設計転換（詳細は設計書） |
| 2026-04-18 | **構想スコープを再定義**。単なるAgentforce置換ではなく「**Salesforce SSOT + ローカルLLM + ローカルUI + 周辺アプリ連携**」を軸に据え直し。社内SE勉強会テーゼ「**Salesforceの価値はUIではなく data/governance/identity foundation へ移る**」の実証デモへ |
| 2026-04-18 追加 | **Microsoft Foundry Local が Gemma 4 を正式対応（2026-04-14公開）**を契機に、ローカルLLM構成を再評価。「**Microsoft公式 × Google DeepMind Gemma 4 × Whisper 同梱**」で勉強会テーゼ「AIはローカルへ、産業トレンドとして大手ベンダが本気で張っている」を2大ベンダの構図として直接語れる材料が揃った |

---

## 1. コンセプト（2026-04-18 再定義版）

**Salesforce を SSOT（Single Source of Truth）とする営業業務を、ローカルLLM + ローカルアプリ（UI）+ 周辺アプリ連携で効率的に回すデモ。**

### 1.1 本構想が実証したい3つの命題

1. **UI層はSalesforceを離れうる** — Claude Desktop / Gradio / Tauri / カスタムLWC、複数のフロントエンドが同じMCP契約で相互運用可能
2. **LLMは組織の外に依存しない** — ローカル実行（mlx-lm / Foundry Local等）で機密保持・コストゼロ・オフライン動作が現実解
3. **だがデータの真実性・ガバナンス・アイデンティティ管理は Salesforce が担い続ける** — Per-User OAuth・FLS・共有ルール・監査ログは Hosted MCP にネイティブ継承

→ **「SaaS is Dead議論」への具体的回答**: SalesforceのUI層価値はAIの無償化で相対的に低下するが、**SSOTとしての構造的価値（信頼されたデータ・権限モデル・監査基盤）はむしろ高まる**。

### 1.2 Local Headless 360 の位置付け（2026-04-11版からの継続）

Manufacturing Cloud 2.0が「Salesforce純正Manufacturing Cloudに似て非なる、業務密着の付加価値カスタム実装」だったのと同じ発想で、Agentforceに対する**似て非なるカスタム実装**。両者は競合せず、用途で棲み分ける。

ただし本構想の真の射程は Agentforce 代替に留まらず、**Salesforce SSOT + ローカルAI + 周辺アプリ統合** による営業業務プラットフォームの再構成にある。

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
- **LLM推論とAgent Runtimeは分離**: Agent Runtime + MCPサーバーはCPU-onlyの軽量プロセス。LLMは差し替え可能（ローカルLLM主軸、API LLMは対比用）
- **Salesforceは器（= SSOT）**: System of Record + 認可基盤として使う。顧客・商談・契約・BOMの一次情報はすべてここ
- **MCPが契約**: 各コンポーネント間はMCP（Model Context Protocol）で接続
- **権限はネイティブ継承**: Per-User OAuthで各ユーザーのRunning Userコンテキストを保ち、FLS・共有ルールを完全に効かせる
- **周辺アプリも同じMCP構造で束ねる**: Gmail / Google Calendar / Drive 等もMCP経由でAgent Runtimeに接続し、**SalesforceをSSOTとしつつ周辺データ・ワークフローと統合**した営業ループを実現

### 周辺連携のスコープ（2026-04-18 追加）

| 連携先 | 目的 | 扱う情報の性質 |
|---|---|---|
| **Salesforce（SSOT）** | 顧客・商談・契約・BOM・活動 | 一次情報（組織の真実） |
| Gmail | メール下書き・送信・検索 | 周辺情報（個人のコミュニケーション） |
| Google Calendar | 商談予定確認・会議設定 | 周辺情報（予定・稼働状況） |
| Google Drive | 過去提案書・契約書・図面 | 周辺情報（非構造化ドキュメント） |
| ローカルファイル | CSV/PDFドロップ（その場限り） | 揮発情報 |
| Web検索 | 企業動向・業界ニュース | 外部情報 |

**設計原則**: SSOT（Salesforce）の情報を基軸に、周辺情報を LLM コンテキストで結合する。周辺情報から得た洞察が重要な業務判断に至る場合は、**最終的にSalesforceに書き戻してSSOT性を保つ**。

### Agentforceとの棲み分け

| 用途 | Agentforce | Local Headless 360（本構想） |
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

> ⚠️ **本節は構想ベース。最新の4層構成および周辺連携パターン比較は [lh360-design.md](./lh360-design.md) を参照。**
>
> 構想初期（2026-04-14）は「自作MCPサーバー」前提。その後 Salesforce Hosted MCP (GA) の実態判明により、**「標準MCP + Custom MCP + Agent Runtime + ローカルUI」の4層構成**へ再設計済み。2026-04-18 時点で Phase 0（Hosted MCP sobject-all + Claude Desktop 接続）動作確認完了。

### 全体構成（概念レベル）

**設計判断: LLM推論とAgent Runtimeの分離**

Agent Runtime + MCPサーバーはCPU-onlyの軽量プロセスであり、GPU VMは不要。**ローカルLLM（mlx-lm / Foundry Local等）を主軸**とし、Claude API / Gemini API は対比・緊急避難用とする位置付け。

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

| クライアント | 用途 | 実装の重さ | 本デモでの位置付け |
|---|---|---|---|
| **Claude Desktop** | 動作検証、管理者作業、パワーユーザー | ゼロ（既存）| **Phase 0 接続済（2026-04-18）** |
| **Gradio ローカルアプリ** | 勉強会デモ主軸UI、ローカルLLM統合、音声I/O | 小〜中 | **MVP。シナリオA/B/C全て対応** |
| **Tauri ネイティブアプリ** | 配布・本番想定、Whisper統合 | 中〜大 | 将来移行先 |
| **LWC薄チャット** | Salesforceに常駐する一般ユーザー | 中 | Salesforce内統合デモ用 |

**本デモのUI戦略**: 
- Phase 0: Claude Desktop で Hosted MCP 動作確認 → **完了**
- Phase 1: Gradio ローカルアプリ + ローカルLLM + Salesforce MCP
- Phase 2: Gmail/Calendar/Drive MCP を Gradio 側に追加統合
- Phase 3: 音声ロールプレイ（Whisper + TTS）、必要に応じて Tauri 移行
- Phase 4（選択肢）: LWC 統合版でSalesforce画面内でも動作させる

---

## 8. デプロイ戦略

### 本デモ構成（主軸）: ローカルMac完結

勉強会デモはすべて**プレゼン者のMacローカルで完結**させる。クラウド依存ゼロが本構想のメッセージ性を最大化する。

| コンポーネント | 実装 | コスト |
|---|---|---|
| Agent Runtime | ローカルPython（Gradio） | ゼロ |
| LLM推論 | **mlx-lm + Gemma 4 26B MoE**（主軸）| 電気代のみ |
| LLM推論（比較用） | — （Foundry Localは今回スコープ外、将来再評価）| — |
| Salesforce MCP | 標準Hosted MCP（クラウド側） | 現時点料金体系不明 |
| 周辺MCP | Gmail / Calendar / Drive の公式/コミュニティMCP | ゼロ〜少額 |
| 会話履歴 | インメモリ | ゼロ |

### ローカルLLMランタイム方針（2026-04-18 確定）

**本命: mlx-lm + Gemma 4 26B MoE**（Apple Silicon最適、26B MoE動作確認済）で Phase 1 を推進。

**Foundry Local は今回のデモスコープから除外**。理由:
- macOS Foundry Local カタログ実測（2026-04-18）で **Gemma/Llama系は一切搭載されておらず**、2024年末までの Phi / Qwen2.5 と Qwen3-0.6b のみ
- 2026-04-14 Microsoftブログ「Gemma 4 now available in Microsoft Foundry」は **Azure AI Foundry（クラウド）側** の話だった
- Gemma 4 世代（E4B マルチモーダル、26B A4B、31B 256K）と比較して明確に見劣り
- tool calling 自体は qwen2.5-1.5b-GPU で動作確認済（chat 0.89s / tool call 0.87s、WebGPU経由Metal）→ 将来再開時の初期コストはゼロ

**将来再評価のトリガー**（宿題）: Microsoft が macOS Foundry Local で Gemma / Llama 系を追加した段階で、Secondary 位置付け（比較デモ・Whisper音声ノート Phase 3）として再検討。Azure側対応 × Gemma 4 の業界バズを踏まえると、追加は時間の問題と推定。

### 戦略的意義: Gemma 4 × Apple Silicon の最新組み合わせ

本デモは **Google DeepMind 最新 Gemma 4** を **Apple Silicon MLX** で動かす。これは 2026-04 時点の on-device AI の最先端構成であり、「AIは組織の外に出ずに、しかも最新モデル品質で動く」という勉強会テーゼを最も強く実証できる。

### 将来構成（選択肢）

| 目的 | 構成 |
|---|---|
| Salesforce LWC統合 | Cloud Run（Agent Runtime）+ ローカルLLM（トンネリング or API LLM） |
| 本番スケール | vLLM on Linux GPU + Cloud Run |
| 顧客環境デプロイ | Mac Studio 設置 or オンプレLinux + GPU |

---

## 9. ロードマップ（2026-04-18 更新版）

> 旧ロードマップ（自作MCP + LWC優先）は Hosted MCP GAにより不要化。4層構成へ再構築済み。詳細は設計書 Section 9 参照。

### Phase 0: Hosted MCP実地検証 — **完了（2026-04-18）**
- [x] Hosted MCP sobject-all 有効化（BPS sandbox org）
- [x] External Client App 作成（PKCE + JWT + `mcp_api` scope）
- [x] Claude Desktop 接続、日本語クエリ・更新動作確認
- [x] 既知問題を [known-issues.md](../reference/known-issues.md) に記録
- 成果: 「Claude Desktop → Hosted MCP → Salesforce」のラインが動作する前提が確立

### Phase 1: ローカルUIアプリ + ローカルLLM — **進行中**
- [ ] Gradio runtime スケルトン（LLM Client抽象 + MCP Client）
- [ ] mlx-lm との接続（テキストチャットのみ）
- [ ] Salesforce MCP 接続（公式MCP Python SDK）
- [ ] シナリオA（リード抽出 → ListView → メール）通し試験
- 成果: 「ローカルLLMがSalesforceを操作する」基本線

### Phase 2: 周辺アプリ連携
- [ ] Gmail MCP 接続（過去メール検索・下書き作成）
- [ ] Google Calendar MCP 接続（予定確認・会議設定）
- [ ] Google Drive MCP 接続（過去提案書参照）
- [ ] シナリオB（ドキュメント解釈）通し試験
- [ ] Foundry Local セカンダリ検証（比較デモ用）
- 成果: 「Salesforce SSOT + 周辺アプリ連携」の統合デモ

### Phase 3: 音声ロールプレイ
- [ ] mlx-whisper 統合（or Foundry Local 内蔵Whisper）
- [ ] TTS 統合
- [ ] シナリオC（製品トーク練習）通し試験
- 成果: マルチモーダル対応、ローカル音声AI実証

### Phase 4（選択肢）: Salesforce LWC 統合版
- [ ] Custom MCP Server 構築（BPS固有ツール）
- [ ] Cloud Run Agent Runtime デプロイ
- [ ] LWC 薄チャット実装
- [ ] キラーデモ LWC 通し試験
- 成果: Salesforce画面内でも同じ体験が動作する

### Phase 5: 勉強会本番
- [ ] デモシナリオ リハーサル
- [ ] プレゼン資料（SSOT論 + 業界トレンド + 技術実証）
- [ ] 実演

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

### G. 周辺アプリ連携のMCP構成（2026-04-18 追加）
Gmail / Calendar / Drive を Agent Runtime に束ねる際の3パターン（詳細比較は設計書 Section 12.G）：
- パターン①: Agent Runtime側で各MCPサーバーに接続
- パターン②: UIアプリ側で全MCP接続、Agent Runtimeは Salesforce MCP のみ
- パターン③: 独自統合Tool層（MCPを使わず直接API）

**現時点の仮決定**: パターン② or ①。勉強会テーゼ「ローカル完結」にはパターン②が最も整合。

### H. 過去ドキュメントのRAG戦略（2026-04-18 追加）
過去提案書・契約書・図面をコンテキストに載せる方法：
- A案: **Salesforce Data Cloud の Vector Search**（このorgで構築済）を MCP 経由で呼ぶ ← **SSOT論と最も整合**
- B案: ローカルChroma/Qdrant
- C案: Google Drive MCPで都度検索

勉強会テーゼ「SalesforceはSSOT」を貫くならA案が有力。ただし「ローカル完結」との緊張関係がある論点。

---

## 11. 関連ドキュメント

- [gemma4-installプロジェクト](/Users/satoshi/claude/gemma4-install) - ローカルLLM検証の基盤資産
- [Manufacturing Cloud 2.0](../design/manufacturing-cloud-2.0-design.md) - 同種の「純正に対するカスタム拡張」発想
- [Agentforce アーキテクチャガイド](../reference/agentforce-architecture-guide.md) - 既存Agentforce運用方針
- [Agentforceサーベイ](./agentforce-survey-deep-dive.md) - Agentforce深掘り調査
