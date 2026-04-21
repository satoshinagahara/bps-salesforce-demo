"""`_is_broken_tool_call` / `_generate_with_retry` の単体テスト。

Gemma 4 の tool_call 完全崩壊（finish_reason=tool_calls だが tool_calls=None）
を判定してリトライする層の挙動を検証する。
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any

from agent.loop import AgentConfig, AgentLoop, _is_broken_tool_call


# ---- fake OpenAI response shapes ----
@dataclass
class FakeMessage:
    content: str | None = None
    tool_calls: list | None = None


@dataclass
class FakeChoice:
    finish_reason: str
    message: FakeMessage


@dataclass
class FakeResponse:
    choices: list


def run_case(name: str, condition: bool) -> None:
    status = "✅" if condition else "❌"
    print(f"{status} {name}")
    if not condition:
        raise AssertionError(name)


# ---- tests for _is_broken_tool_call ----
def test_is_broken_tool_call() -> None:
    # 1. finish_reason=stop → not broken
    c = FakeChoice(finish_reason="stop", message=FakeMessage(content="hi"))
    run_case("[broken] finish_reason=stop → False", _is_broken_tool_call(c) is False)

    # 2. finish_reason=tool_calls AND tool_calls exist → not broken
    c = FakeChoice(finish_reason="tool_calls", message=FakeMessage(tool_calls=[object()]))
    run_case("[broken] tool_calls present → False", _is_broken_tool_call(c) is False)

    # 3. finish_reason=tool_calls AND tool_calls=None → broken
    c = FakeChoice(finish_reason="tool_calls", message=FakeMessage(tool_calls=None))
    run_case("[broken] tool_calls=None → True", _is_broken_tool_call(c) is True)

    # 4. finish_reason=tool_calls AND tool_calls=[] → broken
    c = FakeChoice(finish_reason="tool_calls", message=FakeMessage(tool_calls=[]))
    run_case("[broken] tool_calls=[] → True", _is_broken_tool_call(c) is True)

    # 5. finish_reason=length with no tool_calls → not broken (different failure mode)
    c = FakeChoice(finish_reason="length", message=FakeMessage(tool_calls=None))
    run_case("[broken] finish_reason=length → False", _is_broken_tool_call(c) is False)


# ---- tests for _generate_with_retry ----
class FakeCompletions:
    """`client.chat.completions.create` のモック。

    計画された choice シーケンスを順番に返す。
    呼ばれた temperature を記録する。
    """

    def __init__(self, choices: list[FakeChoice]) -> None:
        self._choices = list(choices)
        self.calls: list[dict] = []

    async def create(self, **kwargs) -> FakeResponse:
        self.calls.append(kwargs)
        c = self._choices.pop(0)
        return FakeResponse(choices=[c])


class FakeChat:
    def __init__(self, completions: FakeCompletions) -> None:
        self.completions = completions


class FakeClient:
    def __init__(self, completions: FakeCompletions) -> None:
        self.chat = FakeChat(completions)


def _make_loop(planned: list[FakeChoice]) -> tuple[AgentLoop, FakeCompletions]:
    cfg = AgentConfig(retry_temperatures=(0.5, 0.8))
    # mcp_manager は使わないので、AgentLoop を通常通り作ると system_prompt 読み込みが必要。
    # __new__ で回避して最小状態を注入する。
    loop = AgentLoop.__new__(AgentLoop)
    loop.cfg = cfg
    comps = FakeCompletions(planned)
    loop.client = FakeClient(comps)
    return loop, comps


def test_retry_first_attempt_succeeds() -> None:
    ok = FakeChoice(finish_reason="tool_calls", message=FakeMessage(tool_calls=[object()]))
    loop, comps = _make_loop([ok])
    result = asyncio.run(loop._generate_with_retry([], []))
    run_case("[retry] first attempt succeeds → 1 call", len(comps.calls) == 1)
    run_case("[retry] first attempt used base temperature",
             comps.calls[0]["temperature"] == 0.1)
    run_case("[retry] returns successful choice", result.finish_reason == "tool_calls")


def test_retry_recovers_on_second_attempt() -> None:
    broken = FakeChoice(finish_reason="tool_calls", message=FakeMessage(tool_calls=None))
    ok = FakeChoice(finish_reason="tool_calls", message=FakeMessage(tool_calls=[object()]))
    loop, comps = _make_loop([broken, ok])
    result = asyncio.run(loop._generate_with_retry([], []))
    run_case("[retry] broken then ok → 2 calls", len(comps.calls) == 2)
    run_case("[retry] second attempt escalated temperature",
             comps.calls[1]["temperature"] == 0.5)
    run_case("[retry] returns recovered choice",
             result.message.tool_calls is not None and len(result.message.tool_calls) > 0)


def test_retry_exhausts_all_attempts() -> None:
    broken = lambda: FakeChoice(finish_reason="tool_calls", message=FakeMessage(tool_calls=None))
    loop, comps = _make_loop([broken(), broken(), broken()])
    result = asyncio.run(loop._generate_with_retry([], []))
    run_case("[retry] all broken → 3 calls (1 base + 2 retries)", len(comps.calls) == 3)
    run_case("[retry] temperatures escalated in order",
             [c["temperature"] for c in comps.calls] == [0.1, 0.5, 0.8])
    run_case("[retry] returns last broken choice (not None)",
             result is not None and _is_broken_tool_call(result))


def test_retry_not_triggered_on_normal_finish() -> None:
    # finish_reason=stop は崩壊ではないので初回で返す
    stop = FakeChoice(finish_reason="stop", message=FakeMessage(content="done"))
    loop, comps = _make_loop([stop])
    result = asyncio.run(loop._generate_with_retry([], []))
    run_case("[retry] finish_reason=stop → no retry", len(comps.calls) == 1)
    run_case("[retry] returns stop choice", result.finish_reason == "stop")


def main() -> None:
    test_is_broken_tool_call()
    test_retry_first_attempt_succeeds()
    test_retry_recovers_on_second_attempt()
    test_retry_exhausts_all_attempts()
    test_retry_not_triggered_on_normal_finish()
    print("\nall passed.")


if __name__ == "__main__":
    main()
