"""Agent Loop CLI — ターミナルから対話テスト。

使用例:
    uv run python -m agent.cli                       # 全 MCP (sf + google + fetch)
    uv run python -m agent.cli --only salesforce     # Salesforce MCP のみ
    uv run python -m agent.cli --only salesforce -q "今四半期の優先商談を教えて"
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

from .loop import (
    AgentConfig,
    AgentLoop,
    EvAssistantText,
    EvFinish,
    EvToolCallResult,
    EvToolCallStart,
)
from .mcp_manager import MCPManager, MCPServerSpec

logger = logging.getLogger("agent.cli")
ROOT = Path(__file__).resolve().parents[1]

# ANSI colors
C_CYAN = "\033[36m"
C_YELLOW = "\033[33m"
C_GREEN = "\033[32m"
C_RED = "\033[31m"
C_DIM = "\033[2m"
C_RESET = "\033[0m"


def _sf_username() -> str | None:
    """メインプロジェクトの sf-config.json から target org username を読む。"""
    cfg_path = Path(os.environ.get(
        "SF_CONFIG_PATH", ROOT.parent / "sf-config.json"
    ))
    if not cfg_path.exists():
        return None
    try:
        return json.loads(cfg_path.read_text(encoding="utf-8")).get("username")
    except Exception as e:
        logger.warning(f"failed to read sf-config.json: {e}")
        return None


def _google_creds_ok() -> bool:
    p = Path(os.environ.get(
        "GOOGLE_OAUTH_CREDENTIALS", ROOT / "config" / "tokens" / "google_credentials.json"
    ))
    return p.exists()


def _build_specs(only: str | None) -> list[MCPServerSpec]:
    specs: list[MCPServerSpec] = []

    # 公式 Salesforce MCP (@salesforce/mcp) — sf CLI 認証を参照
    if only in (None, "salesforce"):
        sf_user = _sf_username()
        if sf_user:
            specs.append(MCPServerSpec(
                name="sf",
                command="npx",
                args=[
                    "-y", "@salesforce/mcp",
                    "--orgs", sf_user,
                    "--toolsets", "core,data,orgs",
                    "--no-telemetry",
                ],
            ))
        else:
            logger.warning("sf-config.json not found or missing username; sf MCP disabled")

    # 自作 Google Workspace MCP (Calendar / Gmail)
    if only in (None, "google"):
        if _google_creds_ok():
            specs.append(MCPServerSpec(name="gw", module="mcp_servers.google_mcp"))

    # 公式 Anthropic reference MCPs (汎用基盤層)
    if only is None:
        # 汎用 HTTP fetch
        specs.append(MCPServerSpec(name="fetch", command="uvx", args=["mcp-server-fetch"]))
        # 現在時刻・TZ 変換
        specs.append(MCPServerSpec(name="time", command="uvx", args=["mcp-server-time"]))
        # ローカルファイル操作（スコープを workspace/ に限定）
        workspace_path = ROOT / "workspace"
        workspace_path.mkdir(exist_ok=True)
        specs.append(MCPServerSpec(
            name="fs",
            command="npx",
            args=["-y", "@modelcontextprotocol/server-filesystem", str(workspace_path)],
        ))
        # 知識グラフ形式の永続メモリ
        memory_path = ROOT / "data" / "memory.json"
        memory_path.parent.mkdir(exist_ok=True)
        specs.append(MCPServerSpec(
            name="memory",
            command="npx",
            args=["-y", "@modelcontextprotocol/server-memory"],
            env={"MEMORY_FILE_PATH": str(memory_path)},
        ))

    return specs


async def main():
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", choices=["salesforce", "google"], help="特定MCPのみ")
    parser.add_argument("-q", "--query", help="1発投げて終了するワンショット")
    parser.add_argument("--model", default=os.environ.get("MLX_MODEL"))
    parser.add_argument("--max-turns", type=int, default=int(os.environ.get("AGENT_MAX_TURNS", "8")))
    args = parser.parse_args()

    specs = _build_specs(args.only)
    cfg = AgentConfig()
    if args.model:
        cfg.model = args.model
    cfg.max_turns = args.max_turns

    print(f"{C_DIM}[Agent] model={cfg.model} servers={[s.name for s in specs]}{C_RESET}")

    async with MCPManager(specs) as mgr:
        print(f"{C_DIM}[Agent] {len(mgr.tools)} tools registered:{C_RESET}")
        for t in mgr.tools:
            print(f"{C_DIM}  - {t.qualified_name}{C_RESET}")

        agent = AgentLoop(mgr, cfg=cfg)
        history: list[dict] = []

        async def _run_once(user_msg: str):
            nonlocal history
            print(f"\n{C_CYAN}[User]{C_RESET} {user_msg}\n")
            collected_text = []
            async for ev in agent.run(user_msg, history):
                if isinstance(ev, EvAssistantText):
                    print(f"{C_GREEN}[Assistant]{C_RESET} {ev.text}")
                    collected_text.append(ev.text)
                elif isinstance(ev, EvToolCallStart):
                    print(f"{C_YELLOW}→ tool {ev.name}({_fmt_args(ev.arguments)}){C_RESET}")
                elif isinstance(ev, EvToolCallResult):
                    mark = "✗" if ev.is_error else "✓"
                    color = C_RED if ev.is_error else C_DIM
                    print(f"  {color}{mark} {ev.name}: {ev.result_summary}{C_RESET}")
                elif isinstance(ev, EvFinish):
                    print(f"{C_DIM}[finish] reason={ev.reason} turns={ev.turns}{C_RESET}")
            # 履歴に追加（簡易: textのみ）
            history.append({"role": "user", "content": user_msg})
            if collected_text:
                history.append({"role": "assistant", "content": "\n".join(collected_text)})

        if args.query:
            await _run_once(args.query)
            return

        print(f"{C_DIM}Interactive mode. Ctrl+D or 'exit' to quit.{C_RESET}")
        while True:
            try:
                line = input(f"\n{C_CYAN}> {C_RESET}").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if line.lower() in ("exit", "quit", ":q"):
                break
            if not line:
                continue
            await _run_once(line)


def _fmt_args(args: dict) -> str:
    s = ", ".join(f"{k}={_shorten(v)}" for k, v in args.items())
    return s[:120] + ("…" if len(s) > 120 else "")


def _shorten(v):
    s = str(v)
    return s[:40] + "…" if len(s) > 40 else s


if __name__ == "__main__":
    asyncio.run(main())
