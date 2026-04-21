"""Planner state machine (orchestrator)。

Phase α-3:
- Claude Sonnet による本物のプラン生成 (β catalog 参照)
- 1-step plan → full Executor 直行
- N-step plan → 各 step を full Executor で順次実行、最後に synthesis
- Planner 失敗時はダミー 1-step full にフォールバック

Phase α-1 のダミー挙動は `PlannerLLM=None` で渡せば再現可能。

【ポリシー】
- 会話履歴は Orchestrator (= Planner) が所有
- 1-step plan: Executor に history 素通し (B 相当の挙動)
- N-step plan: Executor に history=[] + task_description + context_json を渡す
  → 各 step は独立した小タスクとして実行される
- synthesis: N-step のときだけ Sonnet を呼ぶ (1-step は Executor 応答をそのまま)

設計: docs/in-progress/lh360-plan-executor-design.md
議論: docs/concepts/lh360-plan-executor-reframing.md
"""
from __future__ import annotations

import json
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import AsyncIterator, Literal

from agent.atomic import AtomicExecutor
from agent.escalate import EscalateExecutor
from agent.loop import AgentLoop, EvAssistantText, EvFinish, Event

from .beta_catalog import BetaCatalog
from .llm import PlannerLLM
from .plan_schema import Plan, StepResult, TaskSpec
from .semantic_layer import SemanticLayer, WorkspaceSemanticLayer


logger = logging.getLogger("planner.orchestrator")


# ---- Planner 固有の UI イベント ----
@dataclass
class EvPlanCreated:
    kind: Literal["plan_created"] = "plan_created"
    plan_id: str = ""
    user_intent: str = ""
    classification: str = "trivial"
    steps: list[dict] = field(default_factory=list)
    synthesis_hint: str = ""
    fallback: bool = False  # Planner 失敗時 True


@dataclass
class EvStepStart:
    kind: Literal["step_start"] = "step_start"
    step_id: str = ""
    mode: str = ""
    elementary_id: str | None = None
    task_description: str = ""


@dataclass
class EvStepEnd:
    kind: Literal["step_end"] = "step_end"
    step_id: str = ""
    status: str = "ok"
    summary: str = ""


OrchEvent = EvPlanCreated | EvStepStart | EvStepEnd | Event


# ---- Orchestrator ----
class Orchestrator:
    """Plan-Executor の指揮者。

    Phase α-3 実装:
    - `planner_llm` と `catalog` が両方与えられたら Sonnet でプラン生成
    - 片方でも None なら α-1 互換のダミー Planner (1-step full)
    - 例外時も安全にダミーへフォールバック
    """

    def __init__(
        self,
        full_executor: AgentLoop,
        planner_llm: PlannerLLM | None = None,
        catalog: BetaCatalog | None = None,
        atomic_executor: AtomicExecutor | None = None,
        escalate_executor: EscalateExecutor | None = None,
        semantic_layer: SemanticLayer | None = None,
        workspace_semantic_layer: WorkspaceSemanticLayer | None = None,
    ):
        self.full_executor = full_executor
        self.planner_llm = planner_llm
        self.catalog = catalog
        self.atomic_executor = atomic_executor
        self.escalate_executor = escalate_executor
        self.semantic_layer = semantic_layer
        self.workspace_semantic_layer = workspace_semantic_layer
        self._planner_system_prompt: str | None = None
        self._synthesis_system_prompt: str | None = None

    # ---- public entry ----
    async def run(
        self,
        user_message: str,
        history: list[dict] | None = None,
    ) -> AsyncIterator[OrchEvent]:
        history = history or []

        # 1. plan 生成
        plan, fallback = await self._safe_generate_plan(user_message, history)

        yield EvPlanCreated(
            plan_id=plan.plan_id,
            user_intent=plan.user_intent,
            classification=("trivial" if len(plan.steps) <= 1 else "complex"),
            steps=[
                {
                    "step_id": s.step_id,
                    "mode": s.mode,
                    "elementary_id": s.elementary_id,
                    "desc": s.task_description,
                }
                for s in plan.steps
            ],
            synthesis_hint=plan.synthesis_hint,
            fallback=fallback,
        )

        # 2. dispatch
        multi_step = len(plan.steps) > 1
        step_results: dict[str, StepResult] = {}

        for step in plan.steps:
            yield EvStepStart(
                step_id=step.step_id,
                mode=step.mode,
                elementary_id=step.elementary_id,
                task_description=step.task_description,
            )

            # Executor 実行 + 最終応答テキストを収集
            final_text_parts: list[str] = []
            async for ev in self._dispatch(step, user_message, history, step_results, multi_step):
                if isinstance(ev, EvAssistantText):
                    final_text_parts.append(ev.text)
                    # multi-step 時は中間 Executor テキストは UI に流さず synthesis で統合
                    if multi_step:
                        continue
                if isinstance(ev, EvFinish) and multi_step:
                    # 中間 step の EvFinish は最終扱いにしない (UI が完了表示してしまう)
                    continue
                yield ev

            summary = "".join(final_text_parts).strip()
            step_results[step.step_id] = StepResult(
                step_id=step.step_id, status="ok", summary=summary
            )
            yield EvStepEnd(step_id=step.step_id, status="ok", summary=summary[:200])

        # 3. multi-step のときは synthesis をストリーム
        if multi_step and self.planner_llm is not None:
            try:
                async for delta in self._synthesize_stream(
                    user_message, plan, step_results
                ):
                    yield EvAssistantText(text=delta)
            except Exception as e:
                logger.exception("synthesis failed; emitting fallback summary")
                # 失敗時: 各 step の summary をそのまま束ねて返す
                fallback_text = _fallback_synthesis(plan, step_results)
                yield EvAssistantText(text=fallback_text)
            yield EvFinish(reason="synthesized", turns=len(plan.steps))

    # ---- plan generation ----
    async def _safe_generate_plan(
        self, user_message: str, history: list[dict]
    ) -> tuple[Plan, bool]:
        """Planner LLM でプラン生成。失敗時はダミーにフォールバック。

        戻り値: (plan, fallback_flag)
        """
        if self.planner_llm is None or self.catalog is None:
            logger.info("[planner] using dummy planner (no Sonnet / catalog)")
            return self._dummy_plan(user_message), True

        try:
            system = self._get_planner_system_prompt()
            user_prompt = _build_planner_user_prompt(user_message, history)
            raw = await self.planner_llm.generate_plan_json(system, user_prompt)
            plan = _plan_from_json(
                raw,
                allow_atomic=self.atomic_executor is not None,
                allow_escalate=self.escalate_executor is not None,
            )
            logger.info(
                f"[planner] plan generated: id={plan.plan_id} "
                f"steps={len(plan.steps)} intent={plan.user_intent!r}"
            )
            return plan, False
        except Exception as e:
            logger.exception(f"planner failed; falling back to 1-step full: {e}")
            return self._dummy_plan(user_message), True

    def _dummy_plan(self, user_message: str) -> Plan:
        plan_id = f"p-{datetime.now().strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
        return Plan(
            plan_id=plan_id,
            user_intent=user_message.strip()[:120],
            steps=[
                TaskSpec(
                    step_id="s1",
                    mode="full",
                    task_description=user_message,
                    success_criteria="ユーザの質問に回答するか、必要な情報を返す",
                )
            ],
            synthesis_hint="",
        )

    # ---- dispatch ----
    async def _dispatch(
        self,
        step: TaskSpec,
        user_message: str,
        history: list[dict],
        prior_results: dict[str, StepResult],
        multi_step: bool,
    ) -> AsyncIterator[Event]:
        if step.mode == "full":
            if multi_step:
                # multi-step: 各 step は独立タスクとして Executor に投げる (history=[])
                enriched = _build_step_user_message(step, prior_results)
                async for ev in self.full_executor.run(enriched, history=[]):
                    yield ev
            else:
                # 1-step: user 発話 + 会話履歴をそのまま Executor に流す
                async for ev in self.full_executor.run(user_message, history=history):
                    yield ev
            return

        if step.mode == "atomic":
            if self.atomic_executor is None:
                # atomic が未配線なら full にフォールバック
                logger.warning(
                    f"[dispatch] atomic requested for {step.step_id} but "
                    f"no AtomicExecutor wired; falling back to full"
                )
                enriched = _build_step_user_message(step, prior_results)
                hist = [] if multi_step else history
                async for ev in self.full_executor.run(enriched, history=hist):
                    yield ev
                return
            # atomic は常に history=[] + 絞り込み tool
            async for ev in self.atomic_executor.run(
                task_description=step.task_description,
                context=_build_atomic_context(step, prior_results),
                success_criteria=step.success_criteria,
                allowed_tools=step.available_tools,
            ):
                yield ev
            return

        if step.mode == "escalate":
            if self.escalate_executor is None:
                logger.warning(
                    f"[dispatch] escalate requested for {step.step_id} but "
                    f"no EscalateExecutor wired; falling back to full"
                )
                enriched = _build_step_user_message(step, prior_results)
                hist = [] if multi_step else history
                async for ev in self.full_executor.run(enriched, history=hist):
                    yield ev
                return
            async for ev in self.escalate_executor.run(
                task_description=step.task_description,
                context=_build_atomic_context(step, prior_results),
                success_criteria=step.success_criteria,
            ):
                yield ev
            return
        raise ValueError(f"unknown step.mode: {step.mode!r}")

    # ---- synthesis ----
    async def _synthesize_stream(
        self, user_message: str, plan: Plan, step_results: dict[str, StepResult]
    ) -> AsyncIterator[str]:
        assert self.planner_llm is not None
        system = self._get_synthesis_system_prompt()
        user_prompt = _build_synthesis_user_prompt(user_message, plan, step_results)
        async for delta in self.planner_llm.synthesize_stream(system, user_prompt):
            yield delta

    # ---- prompt caching ----
    def _get_planner_system_prompt(self) -> str:
        if self._planner_system_prompt is not None:
            return self._planner_system_prompt
        assert self.planner_llm is not None and self.catalog is not None
        template = self.planner_llm.load_prompt("planner_system")
        semantic_block = (
            self.semantic_layer.as_prompt_block()
            if self.semantic_layer is not None
            else "(セマンティックレイヤー未配線。SF オブジェクトの業務意味に関する事前知識なし)"
        )
        gw_block = (
            self.workspace_semantic_layer.as_prompt_block()
            if self.workspace_semantic_layer is not None
            else "(Workspace セマンティックレイヤー未配線。Gmail/Gcal/fetch の使い分けは tool schema 頼り)"
        )
        rendered = template.replace(
            "{GROUPS_SUMMARY}", self.catalog.groups_summary()
        ).replace(
            "{BETA_CATALOG_TSV}", self.catalog.compact_lines()
        ).replace(
            "{AVAILABLE_TOOLS}", self._render_available_tools()
        ).replace(
            "{SF_SEMANTIC_LAYER}", semantic_block
        ).replace(
            "{GW_SEMANTIC_LAYER}", gw_block
        )
        self._planner_system_prompt = rendered
        return rendered

    def _render_available_tools(self) -> str:
        """Executor の MCP tool 一覧を Planner プロンプト用に整形する。

        atomic モードの available_tools 指定で Planner が選ぶボキャブラリ。
        `qualified_name — description (先頭 1 行)` を 1 行ずつ列挙。
        """
        try:
            tools = self.full_executor.mcp.to_openai_tools()
        except Exception as e:
            logger.warning(f"failed to list MCP tools for planner prompt: {e}")
            return "(tool 一覧の取得に失敗。atomic モードの使用は避けて full を使うこと)"
        lines = []
        for t in tools:
            fn = t.get("function") or {}
            name = fn.get("name", "?")
            desc = (fn.get("description") or "").strip().splitlines()
            first_line = desc[0] if desc else ""
            if len(first_line) > 140:
                first_line = first_line[:137] + "…"
            lines.append(f"- {name} — {first_line}" if first_line else f"- {name}")
        return "\n".join(lines) if lines else "(tool なし)"

    def _get_synthesis_system_prompt(self) -> str:
        if self._synthesis_system_prompt is not None:
            return self._synthesis_system_prompt
        assert self.planner_llm is not None
        self._synthesis_system_prompt = self.planner_llm.load_prompt("synthesis")
        return self._synthesis_system_prompt


# ---- helpers ----
def _build_planner_user_prompt(user_message: str, history: list[dict]) -> str:
    """Planner に渡す user prompt。会話履歴 + 現ターン発話をセクション化。"""
    parts = []
    if history:
        # 直近 5 ターンだけ raw で入れる (古いものは α-3 では割愛)
        recent = history[-10:]  # user/assistant 交互で最大 10 entries ≈ 5 turns
        lines = []
        for h in recent:
            role = h.get("role", "?")
            content = h.get("content", "")
            if not content:
                continue
            lines.append(f"{role}: {content}")
        if lines:
            parts.append("## 直近の会話履歴\n" + "\n".join(lines))
    parts.append(f"## 現ターンのユーザ発話\n{user_message.strip()}")
    parts.append(
        "## 指示\n"
        "上記のユーザ発話に対応する plan を JSON object で出力せよ。JSON 以外は出力しない。"
    )
    return "\n\n".join(parts)


def _build_step_user_message(step: TaskSpec, prior: dict[str, StepResult]) -> str:
    """Executor への入力を構築する (multi-step モード用)。"""
    blocks = [f"【タスク】\n{step.task_description}"]
    if step.context:
        blocks.append(f"【コンテキスト】\n```json\n{json.dumps(step.context, ensure_ascii=False, indent=2)}\n```")
    if step.depends_on:
        dep_summaries = []
        for dep_id in step.depends_on:
            r = prior.get(dep_id)
            if r:
                dep_summaries.append(f"- {dep_id}: {r.summary}")
        if dep_summaries:
            blocks.append("【先行ステップの結果】\n" + "\n".join(dep_summaries))
    if step.success_criteria:
        blocks.append(f"【完了条件】\n{step.success_criteria}")
    return "\n\n".join(blocks)


def _build_atomic_context(step: TaskSpec, prior: dict[str, StepResult]) -> dict:
    """AtomicExecutor に渡す context を組み立てる。

    step.context はそのまま渡し、加えて depends_on の先行結果要約を同梱する。
    Executor は history を持たないため、必要な事実はここに全て詰める責務が
    Planner 側にある。
    """
    ctx = dict(step.context) if step.context else {}
    if step.depends_on:
        deps = {}
        for dep_id in step.depends_on:
            r = prior.get(dep_id)
            if r and r.summary:
                deps[dep_id] = r.summary
        if deps:
            ctx["prior_step_summaries"] = deps
    if step.elementary_id:
        ctx["elementary_id"] = step.elementary_id
    return ctx


def _build_synthesis_user_prompt(
    user_message: str, plan: Plan, step_results: dict[str, StepResult]
) -> str:
    parts = [
        f"## ユーザの元発話\n{user_message.strip()}",
        f"## 解釈された意図\n{plan.user_intent}",
    ]
    if plan.synthesis_hint:
        parts.append(f"## 合成方針\n{plan.synthesis_hint}")
    parts.append("## 各 step の結果")
    for step in plan.steps:
        r = step_results.get(step.step_id)
        summary = r.summary if r else "(結果なし)"
        parts.append(f"### {step.step_id}: {step.task_description}\n{summary}")
    parts.append("## 指示\n上記を束ねてユーザに返す最終回答を生成せよ。")
    return "\n\n".join(parts)


def _plan_from_json(
    raw: dict, allow_atomic: bool = False, allow_escalate: bool = False
) -> Plan:
    """Sonnet の JSON 出力を Plan dataclass に変換。スキーマ違反は例外を上げる。

    allow_atomic:
        True なら mode="atomic" をそのまま通す (α-4 以降、AtomicExecutor が配線済み)。
        False なら atomic は full に矯正 (α-3 互換、または atomic_executor=None 時)。
    allow_escalate:
        True なら mode="escalate" をそのまま通す (α-5 以降、EscalateExecutor が配線済み)。
        False なら escalate は full に矯正。
    """
    plan_id = f"p-{datetime.now().strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:6]}"
    steps_raw = raw.get("steps") or []
    if not isinstance(steps_raw, list) or not steps_raw:
        raise ValueError("plan.steps is empty or not a list")

    steps: list[TaskSpec] = []
    for i, s in enumerate(steps_raw):
        if not isinstance(s, dict):
            raise ValueError(f"step[{i}] is not a dict")
        mode = s.get("mode", "full")
        if mode not in ("full", "atomic", "escalate"):
            mode = "full"
        if mode == "atomic" and not allow_atomic:
            logger.warning(
                f"planner emitted atomic mode for {s.get('step_id')} but "
                "AtomicExecutor not wired; coerced to 'full'"
            )
            mode = "full"
        if mode == "escalate" and not allow_escalate:
            logger.warning(
                f"planner emitted escalate mode for {s.get('step_id')} but "
                "EscalateExecutor not wired; coerced to 'full'"
            )
            mode = "full"
        steps.append(
            TaskSpec(
                step_id=s.get("step_id") or f"s{i+1}",
                mode=mode,
                elementary_id=s.get("elementary_id"),
                task_description=s.get("task_description") or "",
                context=s.get("context") or {},
                available_tools=s.get("available_tools"),
                success_criteria=s.get("success_criteria") or "",
                depends_on=s.get("depends_on") or [],
            )
        )

    return Plan(
        plan_id=plan_id,
        user_intent=raw.get("user_intent", ""),
        steps=steps,
        synthesis_hint=raw.get("synthesis_hint") or "",
    )


def _fallback_synthesis(plan: Plan, step_results: dict[str, StepResult]) -> str:
    """synthesis LLM が失敗した場合の素朴な束ね表示。"""
    parts = []
    for step in plan.steps:
        r = step_results.get(step.step_id)
        if r and r.summary:
            parts.append(f"**{step.step_id}** {step.task_description}\n{r.summary}")
    if not parts:
        return "(結果を合成できませんでした)"
    return "\n\n".join(parts)
