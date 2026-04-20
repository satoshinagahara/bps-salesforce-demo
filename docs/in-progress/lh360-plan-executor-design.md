# lh360 Plan-Executor 設計書

## 位置付け

[lh360-plan-executor-reframing.md](../concepts/lh360-plan-executor-reframing.md) で合意した Plan-Executor 分離アーキテクチャの具体設計。`lh360-usecase-pattern-analysis.md` (β) / `lh360-f-pattern-cloud-offload-design.md` (γ) の成果物を実装に接続するレイヤー。

**日付**: 2026-04-19 起案
**ステータス**: Phase α-1 (ダミー Planner 配線) に着手

---

## 1. モジュール構成

```
lh360/
├─ agent/
│   ├─ loop.py           # 既存 AgentLoop — full モード Executor として温存
│   ├─ atomic.py         # [α-4] atomic モード Executor (max_turns 2-3)
│   └─ mcp_manager.py    # [α-4] tool filter 機能を追加予定
├─ planner/              # [α-1 新設]
│   ├─ __init__.py
│   ├─ orchestrator.py   # state machine: user → plan → dispatch → synthesis
│   ├─ llm.py            # [α-3] Claude Sonnet ラッパ
│   ├─ plan_schema.py    # Plan / TaskSpec dataclass
│   ├─ beta_catalog.py   # [α-3] β elementary カタログの読み込み
│   └─ prompts/
│       ├─ planner_system.md    # [α-3] プラン生成プロンプト
│       └─ synthesis.md         # [α-3] 最終合成プロンプト
├─ data/
│   └─ beta_catalog.yaml        # [α-3] 284 elementary コンパクト版
├─ scripts/
│   └─ build_beta_catalog.py    # [α-3] β 分析 md → YAML 変換
└─ app/
    └─ gradio_app.py            # [α-1] Planner 経由に張り替え
```

α-1 では `planner/orchestrator.py` + `planner/plan_schema.py` のみ新設。他はスタブ。

---

## 2. データ構造

### TaskSpec (Planner → Executor 契約)

```python
@dataclass
class TaskSpec:
    step_id: str                          # "s1", "s2" (プラン内一意)
    elementary_id: str | None             # β catalog の id (例 "P7.1.3")
    mode: Literal["atomic", "full", "escalate"]
    task_description: str                 # Executor に見せる自然文
    context: dict                         # focal_account_ids 等
    available_tools: list[str] | None     # None = 全 tools (Gemma 25 tool 制限注意)
    success_criteria: str
    depends_on: list[str] = field(default_factory=list)
```

### Plan

```python
@dataclass
class Plan:
    plan_id: str
    user_intent: str                      # Planner が解釈した意図 1-2 文
    steps: list[TaskSpec]
    synthesis_hint: str                   # 結果合成の方針
```

### StepResult (Executor → Planner)

```python
@dataclass
class StepResult:
    step_id: str
    status: Literal["ok", "failed", "escalate_requested"]
    summary: str                          # Planner に見せる要約 (生データではない)
    workspace_refs: list[str] = field(default_factory=list)  # 将来: 大容量結果の参照
    error: str | None = None
```

---

## 3. Orchestrator state machine (1 ターン)

```
receive(user_message, history)
  ↓
1. classify(user_message, history) → trivial | complex
     α-1: 常に trivial (ダミー Planner)
     α-3: Claude Sonnet 判定
  ↓
2. generate_plan()
     trivial → 1-step full プラン (現 AgentLoop に丸投げ)
     complex → N-step プラン (β catalog 参照)
  ↓
3. for step in plan.steps (topological order):
     resolve_context(step, prior_results)
     dispatch(step):
       mode=atomic   → AtomicExecutor
       mode=full     → AgentLoop (既存)
       mode=escalate → γ offload (Claude Sonnet, F 型プロンプト)
     prior_results[step.step_id] = StepResult
     if status=="failed":
       retry once with bumped temperature (Executor の既存機構)
       else → synthesis に失敗を申告
  ↓
4. synthesize(user_message, plan, prior_results) → assistant_text
     α-1: Executor の最終応答をそのまま返す
     α-3: Claude Sonnet で合成
  ↓
5. history に <user, assistant> 追加
```

### 失敗時の退避

- Planner LLM 自体がコケる → 「プラン生成に失敗しました」+ **1-step full にフォールバック** (B 相当の動作)
- Executor 失敗 → Planner が retry / escalate / user に報告を選択
- 境界判定失敗 (A-E のはずが F が必要だった) → escalate に振り替え

---

## 4. 会話コンテキスト所有

- **Planner のみが保持**。`(user, assistant)` ペアのリスト。
- Executor は毎回ステートレスで、必要な context は TaskSpec に詰めて渡す
- 照応解決 (「前回の Opp」等) は Planner の責務

履歴圧縮戦略 (α-3 以降):
- 直近 5 ターン raw 保持
- それ以前は Planner が要約して 1 item に畳む

---

## 5. β catalog 配信方式

**初期**: 方式 A (YAML 埋め込み) — 284 elementary × 1 行 ≒ 20-30k tokens を Sonnet system prompt に注入。

**カタログスキーマ**:
```yaml
- id: "P7.1.3"
  group: "P7"
  business_type: "大型案件追跡型"
  title: "stalled opp の抽出"
  description: "stage 滞在日数が閾値超の Opp を listing"
  typical_tools: ["sf__query"]
  pattern: "B"  # A-F
  success_hint: "Opp id/name/stage/滞在日数の一覧"
```

**切替判断ポイント**: Planner token コストが月 $200 を超えた時点で方式 C (business type manifest で絞り込み) に切替検討。

---

## 6. Executor atomic モード (α-4)

`agent/atomic.py`:
```python
class AtomicExecutor:
    """単発 elementary 実行。max_turns 2-3、history 無し。"""
    def __init__(self, mcp: MCPManager, cfg: AgentConfig | None = None):
        self.cfg = cfg or AgentConfig(max_turns=3)
        self.mcp = mcp

    async def run(self, spec: TaskSpec) -> StepResult:
        # spec を system prompt にコンパイル
        # AgentLoop に history=[] で投げる
        # 最終 assistant_text を summary として返す
```

tool filter は `MCPManager.to_openai_tools(allow: set[str] | None = None)` で実装。Gemma 4 の 25 tool 崩壊対策として必須。

---

## 7. Phase α 実装順序

| Step | 内容 | 完了条件 |
|---|---|---|
| **α-1** | ダミー Planner + 配線 | gradio が Planner 経由で既存動作を維持 |
| α-2 | Plan schema 確定 + UI 実況 (Plan JSON を collapsible で表示) | プラン構造が UI で見える |
| α-3 | Claude Sonnet Planner 本体 + β catalog + synthesis | 複数 step プランが回る |
| α-4 | AtomicExecutor + tool filter | atomic 経路稼働 |
| α-5 | γ escalation 合流 | F 型 offload が Plan 内に入る |
| α-6 | Planner プロンプト磨き込み + β eval | 品質測定 |

---

## 8. α-1 の範囲 (今回実装)

**作るもの**:
- `planner/plan_schema.py` — Plan / TaskSpec / StepResult dataclass
- `planner/orchestrator.py` — ダミー Planner。常に `[TaskSpec(mode="full", ...)]` を返し、AgentLoop に丸投げ
- `planner/__init__.py` — export
- `app/gradio_app.py` — `AgentLoop.run` を `Orchestrator.run` 呼び出しに差し替え

**作らないもの** (α-3 以降):
- Claude Sonnet 接続
- β catalog
- atomic mode
- synthesis prompt
- プランの UI 可視化

**後方互換**: 既存の Gradio 会話は挙動が変わらないこと。Orchestrator は `AgentLoop.Event` をそのまま yield する。

---

## 9. 未決事項 (今後詰める)

1. **Planner の会話履歴保持形式**: OpenAI messages か独自か → **推奨: 直近 5 ターン raw + 古いものは要約**
2. **Executor 中間結果の粒度**: 要約のみ or 生データ参照可 → **推奨: 要約のみ、生データは workspace に保存**
3. **β catalog の粒度絞り込み戦略**: business type で絞るか全量か → **初期は全量**
4. **Plan ログ永続化**: `workspace/plans/*.json` に保存するか → **推奨: 保存 (システムビューで使う)**
5. **非同期キャンセル**: Planner 実行中にユーザが中断したときの挙動 → 後回し

---

## 関連ドキュメント

- [../concepts/lh360-plan-executor-reframing.md](../concepts/lh360-plan-executor-reframing.md) - 設計決定の背景・論点
- [lh360-usecase-pattern-analysis.md](lh360-usecase-pattern-analysis.md) - β 成果物
- [lh360-f-pattern-cloud-offload-design.md](lh360-f-pattern-cloud-offload-design.md) - γ 設計
- [lh360-stocktake.md](lh360-stocktake.md) - プロジェクト全体状況
