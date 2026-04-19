"""Agent 挙動観察用ドライバ（Claude から直接叩くため）。

- MCP を一度だけ起動して複数の user プロンプトを会話として回す
- 各ターンの tool_call / tool_result / assistant テキスト / finish 理由を
  構造化して標準出力に出す
- Gradio を介さないので、Claude 側から直接観察できる

使い方:
    uv run python -m tests.test_agent_driver "prompt1" "prompt2" ...

環境変数:
    AGENT_MCP_SUBSET: カンマ区切りで使う MCP 名を絞る（例: "sf,gw,fetch,time"）
                      未指定時は _current_specs() の全 MCP を使う
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from typing import Any

# gradio_app の _current_specs を再利用（DRY）
from app.gradio_app import _current_specs
from agent.mcp_manager import MCPManager
from agent.loop import (
    AgentConfig,
    AgentLoop,
    EvAssistantText,
    EvFinish,
    EvToolCallResult,
    EvToolCallStart,
)


def _fmt_args(args: dict) -> str:
    s = json.dumps(args, ensure_ascii=False)
    if len(s) > 400:
        s = s[:400] + "…"
    return s


def _hr(ch: str = "=") -> str:
    return ch * 80


async def main():
    if len(sys.argv) < 2:
        print("usage: test_agent_driver.py 'prompt1' ['prompt2' ...]", file=sys.stderr)
        sys.exit(1)
    prompts = sys.argv[1:]

    specs = _current_specs()
    subset = os.environ.get("AGENT_MCP_SUBSET")
    if subset:
        allow = {s.strip() for s in subset.split(",") if s.strip()}
        before = [s.name for s in specs]
        specs = [s for s in specs if s.name in allow]
        print(f"[init] AGENT_MCP_SUBSET={subset!r} → filter {before} → {[s.name for s in specs]}")
    print(_hr())
    print(f"[init] MCP specs: {[s.name for s in specs]}")
    print(_hr())

    async with MCPManager(specs) as mgr:
        by_server: dict[str, list[str]] = {}
        for t in mgr.tools:
            by_server.setdefault(t.server, []).append(t.original_name)
        for s, names in by_server.items():
            print(f"  {s}: {len(names)} tools")
        print(f"  TOTAL: {len(mgr.tools)} tools")
        print(_hr())

        agent = AgentLoop(mgr, cfg=AgentConfig())
        history: list[dict] = []

        for i, prompt in enumerate(prompts, 1):
            print()
            print(_hr("#"))
            print(f"# TURN {i} USER: {prompt}")
            print(_hr("#"))
            assistant_text_parts: list[str] = []
            async for ev in agent.run(prompt, history):
                if isinstance(ev, EvToolCallStart):
                    print(f"[tool_call] {ev.name}({_fmt_args(ev.arguments)})")
                elif isinstance(ev, EvToolCallResult):
                    mark = "ERR" if ev.is_error else "OK "
                    print(f"[tool_result {mark}] {ev.name}: {ev.result_summary}")
                elif isinstance(ev, EvAssistantText):
                    assistant_text_parts.append(ev.text)
                    print(f"[assistant]\n{ev.text}")
                elif isinstance(ev, EvFinish):
                    print(f"[finish] reason={ev.reason} turns={ev.turns}")

            history.append({"role": "user", "content": prompt})
            if assistant_text_parts:
                history.append({
                    "role": "assistant",
                    "content": "\n".join(assistant_text_parts),
                })


if __name__ == "__main__":
    asyncio.run(main())
