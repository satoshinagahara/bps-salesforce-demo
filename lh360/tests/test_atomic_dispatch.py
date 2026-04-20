"""α-4 smoke: atomic mode の dispatch 検証。

外部依存 (MLX / Anthropic / MCP) に触れずに、Orchestrator が
- mode="atomic" の step を AtomicExecutor に正しくルーティングする
- AtomicExecutor 未配線時は atomic → full に coerce される
を検証する。

実行:
  cd lh360
  uv run python -m pytest tests/test_atomic_dispatch.py -q
  # or:
  uv run python tests/test_atomic_dispatch.py
"""
from __future__ import annotations

import asyncio
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import AsyncIterator

# lh360/ を sys.path に入れて planner/agent を import できるようにする
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from agent.loop import EvAssistantText, EvFinish, Event  # noqa: E402
from planner.orchestrator import (  # noqa: E402
    EvPlanCreated,
    EvStepEnd,
    EvStepStart,
    Orchestrator,
)


# ---- Fakes ----
@dataclass
class FakeMCP:
    tools: list[dict] = field(default_factory=list)

    def to_openai_tools(self) -> list[dict]:
        return self.tools


@dataclass
class FakeAgent:
    """full_executor スタンドイン。run() を呼ばれたら記録する。"""
    mcp: FakeMCP = field(default_factory=FakeMCP)
    calls: list[dict] = field(default_factory=list)
    response_text: str = "(full executor reply)"

    async def run(self, user_message: str, history: list[dict] | None = None,
                  allowed_tools: set[str] | None = None) -> AsyncIterator[Event]:
        self.calls.append({
            "user_message": user_message,
            "history": list(history or []),
            "allowed_tools": allowed_tools,
        })
        yield EvAssistantText(text=self.response_text)
        yield EvFinish(reason="stop", turns=1)


@dataclass
class FakeAtomic:
    """AtomicExecutor スタンドイン。run() 呼び出しを記録。"""
    calls: list[dict] = field(default_factory=list)
    response_text: str = "(atomic executor reply)"

    async def run(self, task_description: str, context: dict | None = None,
                  success_criteria: str = "",
                  allowed_tools: list[str] | None = None) -> AsyncIterator[Event]:
        self.calls.append({
            "task_description": task_description,
            "context": context,
            "success_criteria": success_criteria,
            "allowed_tools": allowed_tools,
        })
        yield EvAssistantText(text=self.response_text)
        yield EvFinish(reason="stop", turns=1)


class FakePlannerLLM:
    """返り値を固定する fake Planner。Orchestrator はこれを呼ぶ。"""
    def __init__(self, plan_json: dict, synthesis_text: str = "(synth)"):
        self._plan_json = plan_json
        self._synthesis_text = synthesis_text

    def load_prompt(self, name: str) -> str:
        return "FAKE PROMPT {GROUPS_SUMMARY} {BETA_CATALOG_TSV} {AVAILABLE_TOOLS}"

    async def generate_plan_json(self, system: str, user: str) -> dict:
        return self._plan_json

    async def synthesize_stream(self, system: str, user: str) -> AsyncIterator[str]:
        yield self._synthesis_text


class FakeCatalog:
    elementaries: dict = {}

    def groups_summary(self) -> str:
        return "(fake groups)"

    def compact_lines(self, include_f: bool = True) -> str:
        return "(fake tsv)"


# ---- helpers ----
async def _collect(gen):
    out = []
    async for ev in gen:
        out.append(ev)
    return out


# ---- tests ----
async def test_atomic_routes_to_atomic_executor():
    """mode=atomic の step が AtomicExecutor.run に渡されることを検証。"""
    plan_json = {
        "user_intent": "自担当 pipeline の集計",
        "classification": "trivial",
        "steps": [
            {
                "step_id": "s1", "mode": "atomic", "elementary_id": "e7-5-a",
                "task_description": "Opp を stage 別に集計",
                "context": {"fy": "FY2026"},
                "available_tools": ["sf__query", "sf__describe-object"],
                "success_criteria": "stage ごとの件数/金額一覧",
                "depends_on": [],
            }
        ],
        "synthesis_hint": "",
    }
    agent = FakeAgent()
    atomic = FakeAtomic()
    orch = Orchestrator(
        full_executor=agent,
        planner_llm=FakePlannerLLM(plan_json),
        catalog=FakeCatalog(),
        atomic_executor=atomic,
    )

    events = await _collect(orch.run("今週のパイプライン状況", history=[]))

    # Plan 作成イベントあり・fallback=False
    plans = [e for e in events if isinstance(e, EvPlanCreated)]
    assert len(plans) == 1
    assert plans[0].fallback is False
    assert plans[0].steps[0]["mode"] == "atomic"

    # atomic が呼ばれた
    assert len(atomic.calls) == 1, f"atomic called {len(atomic.calls)} times, expected 1"
    call = atomic.calls[0]
    assert call["task_description"] == "Opp を stage 別に集計"
    assert call["allowed_tools"] == ["sf__query", "sf__describe-object"]
    assert call["success_criteria"] == "stage ごとの件数/金額一覧"
    # context には step.context + elementary_id が同梱される
    assert call["context"]["fy"] == "FY2026"
    assert call["context"]["elementary_id"] == "e7-5-a"

    # full_executor は呼ばれていない
    assert len(agent.calls) == 0, "full_executor should not be invoked for atomic step"

    # 1-step なので synthesis は無し・Executor の reply がそのまま流れる
    texts = [e.text for e in events if isinstance(e, EvAssistantText)]
    assert "(atomic executor reply)" in "".join(texts)
    print("✅ test_atomic_routes_to_atomic_executor")


async def test_atomic_coerced_to_full_when_no_atomic_executor():
    """atomic_executor=None の時、atomic mode は full に coerce されることを検証。"""
    plan_json = {
        "user_intent": "test",
        "classification": "trivial",
        "steps": [
            {
                "step_id": "s1", "mode": "atomic", "elementary_id": "e7-5-a",
                "task_description": "something",
                "context": {},
                "available_tools": ["sf__query"],
                "success_criteria": "",
                "depends_on": [],
            }
        ],
        "synthesis_hint": "",
    }
    agent = FakeAgent()
    orch = Orchestrator(
        full_executor=agent,
        planner_llm=FakePlannerLLM(plan_json),
        catalog=FakeCatalog(),
        atomic_executor=None,   # 未配線
    )

    events = await _collect(orch.run("test", history=[]))

    # step は mode=full に矯正されて出力される
    plans = [e for e in events if isinstance(e, EvPlanCreated)]
    assert plans[0].steps[0]["mode"] == "full", (
        f"expected mode=full after coercion, got {plans[0].steps[0]['mode']}"
    )
    assert len(agent.calls) == 1, "full_executor must be invoked after coercion"
    print("✅ test_atomic_coerced_to_full_when_no_atomic_executor")


async def test_mixed_plan_full_then_atomic():
    """multi-step: s1=full (文脈取得) → s2=atomic (確定タスク) の mixed plan。"""
    plan_json = {
        "user_intent": "mixed",
        "classification": "complex",
        "steps": [
            {
                "step_id": "s1", "mode": "full", "elementary_id": None,
                "task_description": "文脈を取得",
                "context": {}, "available_tools": None,
                "success_criteria": "", "depends_on": [],
            },
            {
                "step_id": "s2", "mode": "atomic", "elementary_id": "e7-5-a",
                "task_description": "s1 の結果をもとに確定",
                "context": {},
                "available_tools": ["sf__query"],
                "success_criteria": "",
                "depends_on": ["s1"],
            },
        ],
        "synthesis_hint": "s1 と s2 を束ねる",
    }
    agent = FakeAgent(response_text="s1 result text")
    atomic = FakeAtomic(response_text="s2 result text")
    orch = Orchestrator(
        full_executor=agent,
        planner_llm=FakePlannerLLM(plan_json, synthesis_text="合成結果"),
        catalog=FakeCatalog(),
        atomic_executor=atomic,
    )

    events = await _collect(orch.run("mixed request", history=[]))

    # s1 は full, s2 は atomic
    assert len(agent.calls) == 1
    assert len(atomic.calls) == 1

    # atomic の context には先行 step 要約が入っている
    ctx = atomic.calls[0]["context"]
    assert "prior_step_summaries" in ctx
    assert ctx["prior_step_summaries"].get("s1") == "s1 result text"

    # step_end が 2 件、synthesis text が最後に流れる
    step_ends = [e for e in events if isinstance(e, EvStepEnd)]
    assert len(step_ends) == 2
    texts = [e.text for e in events if isinstance(e, EvAssistantText)]
    # multi-step: 中間 Executor テキストは UI に出ない、最後に synthesis だけ
    joined = "".join(texts)
    assert "合成結果" in joined
    # 中間 Executor の生テキストは流れない
    assert "s1 result text" not in joined
    assert "s2 result text" not in joined
    print("✅ test_mixed_plan_full_then_atomic")


async def main():
    await test_atomic_routes_to_atomic_executor()
    await test_atomic_coerced_to_full_when_no_atomic_executor()
    await test_mixed_plan_full_then_atomic()
    print("\nall α-4 atomic dispatch tests passed.")


if __name__ == "__main__":
    asyncio.run(main())
