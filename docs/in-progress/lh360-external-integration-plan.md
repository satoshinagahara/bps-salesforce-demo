# lh360 外部統合 (Gmail / Gcal / Web) 実装計画

**位置付け**: lh360 α-5 完了後の次テーマ。SF 以外の MCP (Gmail / Gcal / Web) を Planner がまともに使いこなせるようにする。
**開始**: 2026-04-20
**関連**:
- `docs/design/lh360-f-pattern-cloud-offload-design.md` (α-5 完了)
- `docs/in-progress/lh360-usecase-pattern-analysis.md` (β catalog 出典)
- `lh360/data/sf_semantic_layer.yaml` (SF 側の先行実装。本タスクはこれを横展開する)

---

## 背景 — なぜ必要か

lh360 は最初から SF に限らず Gmail / Gcal / Web 検索 を含む SAE ワークフロー全域を想定したアーキテクチャ。現状:

- **MCP 配線は完了**: `sf`, `gw` (自作 google_mcp = Gmail draft + Gcal 3 tools), `fetch`, `time` が `_build_sales_specs` で登録済
- **β catalog には外部系が 57/284 件 ≈ 20%** (src=e / s+e / u+e) あり、枠は既に張ってある
- **ただし Planner が使いこなせていない**: `{AVAILABLE_TOOLS}` には tool 名+schema しか出ていないので「いつ何のために使うか」の業務ヒントが無い
- **真の Web 検索が無い**: `fetch` は URL 指定の DL のみ。URL 未知のクエリ (例「最新の IR を探して」) で Planner が URL をでっちあげて 404 になる事故が起きる

---

## Phase 構成

### Phase A — Workspace Semantic Layer (最優先・即着手)

**方針**: SF 側 (`sf_semantic_layer.yaml`) で効果確認済の「人が curate した意味 YAML を Planner system prompt に注入」方式をそのまま Gmail / Gcal / fetch / time に横展開する。

**成果物**:
- `lh360/data/gw_semantic_layer.yaml` — 各 MCP tool の業務的使い分けヒント
  - Gmail: `gmail_create_draft` は下書き専用 (送信はユーザ確認)。件名/本文の書き方規約
  - Gcal: `calendar_list_events` (RFC3339 ISO必須) / `calendar_check_availability` (空きスロット判定) / `calendar_create_event` (tentative=True で仮押さえ可)
  - fetch: URL 既知時のみ。HTML は重いので 1 hop 前提、要約は別 step
  - time: タイムゾーン変換ユーティリティ。Gcal と組合せで必須
- `lh360/planner/semantic_layer.py` — 既存 `SemanticLayer` と並列の `WorkspaceSemanticLayer` + `load_workspace_semantic_layer()`
- `lh360/planner/prompts/planner_system.md` — `{GW_SEMANTIC_LAYER}` placeholder を SF セクションの直後に追加
- `lh360/planner/orchestrator.py` — `workspace_semantic_layer` パラメータ追加、`_get_planner_system_prompt()` で置換
- `lh360/agent/scenario.py`, `lh360/app/gradio_app.py` — instantiate + Orchestrator に配線

**検証**:
- 「オメガの鈴木部長に先週やった面談のお礼メール下書きを Gmail に作って」→ plan = `sf__query(Contact.Email) → gw__gmail_create_draft`
- 「来週の月曜午後に鈴木さんと MTG 入れて」→ plan = `gw__calendar_check_availability → gw__calendar_create_event`

### Phase B — Web 検索 provider 追加

**方針**: `fetch` の弱点 (URL 未知クエリ不可) を Web 検索 MCP で埋める。

**候補**:
- **Brave Search MCP** (`@brave/brave-search-mcp` もしくはコミュニティ): 無料枠 2000 req/月、公式性要確認
- **Tavily MCP** (`tavily-mcp`): AI 検索特化、レスポンス要約済、無料 1000/月
- memory feedback `prefer_official_mcp` との整合: Brave/Tavily のどちらが "公式" 扱いかの調査が先。公式が無ければコミュニティ妥協の判断必要

**成果物**:
- `_build_sales_specs` に `brave` or `tavily` spec 追加
- `gw_semantic_layer.yaml` に検索 tool のヒントを追記 (「URL 未知時は検索、URL 既知時は fetch」)
- API key 取得・`.env` or `config/tokens/` への配置

**検証**:
- 「トヨタの最新 IR (中計) を探して要約して」→ plan = `brave_search → fetch → (summarize)`

### Phase C — PII / コスト guardrail (Phase A/B 後)

**方針**: 実データ (Gmail 本文等) をそのまま Sonnet Planner/Escalate に流すと token・PII 両面で問題。tool result filter で圧縮。

**成果物**:
- `MCPManager` or AtomicExecutor に `tool_result_postprocessor` hook
- Gmail: draft result から messageId のみ、send result から summary のみ
- Gcal: list_events から `description` を truncate (default 200 文字)

**判断ポイント**: 早すぎる最適化は避ける。Phase A/B を回した後、実際に「ここ PII 流れてるな」「ここ token 浪費してるな」を計測してから設計する。

### Phase D — β catalog の外部系 task 文言具体化 (判断後)

**方針**: `src=e` / `s+e` / `u+e` の 57 件のうち、Planner が hit 率低い task を具体化。例:
```yaml
- id: e2-7-d
  task: 商談直後のお礼メール下書き作成 (Contact.Email + 直近 Meeting_Record サマリ引用)
  src: s+e
  out: W-e
  hop: 2
```

**判断ポイント**: atomic モードは β catalog に無い task でも自由記述で走るので、catalog 拡充は精度 tuning。blocker ではない。Phase A/B 後にログ見て判断。

### Phase E — Escalate テンプレートの cross-source 対応 (判断後)

F-T1/T3/T5 templates は `context_data` を generic dict で受けるため技術的には cross-source OK。更新するなら `synthesis_hint` 側で「SF 確定事実 / 外部観察 / 未検証情報」を区別させる文言を追加。

---

## 今回 (2026-04-20) の着手範囲

- **Phase A**: 即着手 (このタスク)
- **Phase B**: Phase A 完了後に着手決定済

Phase C 以降は Phase A/B 完了後に再評価。

---

## 実装ログ (2026-04-20)

### Phase A 完了 (Workspace Semantic Layer)

- `lh360/data/gw_semantic_layer.yaml` — Gmail/Gcal/fetch/time の業務的使い分け (7 tool hints)
- `lh360/planner/semantic_layer.py` — `WorkspaceSemanticLayer` + loader 追加
- `lh360/planner/prompts/planner_system.md` — `{GW_SEMANTIC_LAYER}` placeholder
- `lh360/planner/orchestrator.py` / `agent/scenario.py` / `app/gradio_app.py` 配線
- E2E smoke: 「主要 Contact に御礼メール下書き作成」→ `gw__calendar_list_events → gw__gmail_create_draft` で Gmail draft 生成 (messageId `19daa7a7ea8eb7af`)

### Phase B 完了 (Web 検索 Brave Search)

**方針確定**: Brave Search (CC 登録済、Spending Limit Free で課金ブロック)。Tavily は見送り。

**実装**:
- `lh360/agent/scenario.py` / `lh360/app/gradio_app.py` — BRAVE_API_KEY gate で Brave MCP spec 追加
  - Command: `npx -y @brave/brave-search-mcp-server --transport stdio`
  - Tool blocklist: `brave_local_search` / `brave_video_search` / `brave_image_search` / `brave_summarizer`
    → SAE スコープ外 + Gemma 4 の <20 tools 制約遵守のため除外。`brave_web_search` + `brave_news_search` のみ露出
  - `gradio_app.py` の "sales" profile に `brave` 追加
- `lh360/data/gw_semantic_layer.yaml` — `brave_search` セクション追加 (tools / args_hint / common_mistakes / common_pipeline)
- `lh360/planner/prompts/planner_system.md` — 「URL 未知 → brave、既知 → fetch」使い分けルール追記

**E2E smoke** (`/tmp/lh360-brave-e2e.log`):
- Query: 「トヨタ自動車の直近の EV シフト関連の最新ニュースを 1 件調べて要約」
- Registered: `11 tools` (sf/gw/fetch/time/brave 全配線)
- Plan: `atomic:e1-1-e` (業界トレンド記事収集・要約)
- Tool chain: `brave__brave_news_search(freshness=pm, country=JP) → fetch__fetch(selected_url) → summarize` — YAML の common_pipeline 通り
- Planner がクエリを具体化 ("トヨタ自動車 EV 電気自動車 シフト 2025")、freshness・country を指定 — semantic layer の common_mistakes に書いた「1 語抽象クエリ禁止」が効いている

### 次の着手候補 (未決)

- **Phase C (PII / コスト guardrail)**: 実計測後に設計
- **Phase D (β catalog 外部系 task 具体化)**: ログ蓄積後に判断
- **Phase E (Escalate synthesis_hint 強化)**: 必要性まだ不明

lh360 本線側: UI 大改修 + ユーザからの追加トピック 1 件が保留中。
