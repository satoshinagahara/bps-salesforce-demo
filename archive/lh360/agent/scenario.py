"""Plan-Executor Scenario CLI — ターミナルからマルチターンシナリオを一気に流す。

FastAPI バックエンド (app.api) と同じ wiring (Sonnet Planner + AtomicExecutor + history 持ち回し) を
再現し、引数で渡したユーザ発話を順次走らせる。UI 目視を CLI ログで代替するための
β検証用ツール。

使用例:
    cd lh360
    uv run python -m agent.scenario \\
        "今月 Closed Won 取った Opportunity 一覧見せて" \\
        "その中で一番大きい案件の Account と Primary Contact 教えて" \\
        "その Contact に受注お礼メールの下書きを Gmail に作って"
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

from .atomic import AtomicExecutor, load_field_dict
from .escalate import EscalateExecutor
from .loop import (
    AgentConfig,
    AgentLoop,
    EvAssistantText,
    EvFinish,
    EvToolCallResult,
    EvToolCallStart,
)
from .mcp_manager import MCPManager, MCPServerSpec

ROOT = Path(__file__).resolve().parents[1]

# ANSI colors
C_CYAN = "\033[36m"
C_YELLOW = "\033[33m"
C_GREEN = "\033[32m"
C_RED = "\033[31m"
C_MAGENTA = "\033[35m"
C_BLUE = "\033[34m"
C_DIM = "\033[2m"
C_BOLD = "\033[1m"
C_RESET = "\033[0m"

logger = logging.getLogger("agent.scenario")


def _sf_username() -> str | None:
    cfg_path = Path(os.environ.get("SF_CONFIG_PATH", ROOT.parent / "sf-config.json"))
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


def _build_sales_specs() -> list[MCPServerSpec]:
    """app.api.mcp_config の sales profile 相当 (sf + gw + fetch + time)。"""
    specs: list[MCPServerSpec] = []
    sf_user = _sf_username()
    if sf_user:
        sf_project_root = str(ROOT.parent)
        specs.append(MCPServerSpec(
            name="sf",
            command="npx",
            args=[
                "-y", "@salesforce/mcp",
                "--orgs", sf_user,
                "--toolsets", "core,data,orgs",
                "--no-telemetry",
            ],
            argument_overrides={
                "directory": sf_project_root,
                "usernameOrAlias": sf_user,
            },
            tool_blocklist=["get_username", "resume_tool_operation"],
        ))
    if _google_creds_ok():
        specs.append(MCPServerSpec(name="gw", module="mcp_servers.google_mcp"))
    specs.append(MCPServerSpec(name="fetch", command="uvx", args=["mcp-server-fetch"]))
    specs.append(MCPServerSpec(name="time", command="uvx", args=["mcp-server-time"]))
    # Brave Search 公式 MCP — BRAVE_API_KEY があれば Web 検索能力を追加。
    # SAE 用途では web_search / news_search のみ必要なので、残り 4 tool は blocklist で除外
    # (Gemma 4 の <20 tools 制約を守るため + local/video/image は SAE スコープ外)。
    if os.environ.get("BRAVE_API_KEY"):
        specs.append(MCPServerSpec(
            name="brave",
            command="npx",
            args=["-y", "@brave/brave-search-mcp-server", "--transport", "stdio"],
            env={"BRAVE_API_KEY": os.environ["BRAVE_API_KEY"]},
            tool_blocklist=[
                "brave_local_search",
                "brave_video_search",
                "brave_image_search",
                "brave_summarizer",
            ],
        ))
    return specs


def _fmt_args(args: dict, limit: int = 160) -> str:
    s = json.dumps(args, ensure_ascii=False)
    return s if len(s) <= limit else s[:limit - 1] + "…"


async def main():
    load_dotenv()
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    parser = argparse.ArgumentParser()
    parser.add_argument("turns", nargs="+", help="ユーザ発話 (複数指定で連続ターン)")
    args = parser.parse_args()

    # 遅延 import (Planner は ANTHROPIC_API_KEY 必須)
    from planner import (
        PlannerLLM,
        load_catalog,
        load_semantic_layer,
        load_workspace_semantic_layer,
    )
    from planner.orchestrator import (
        EvPlanCreated,
        EvStepEnd,
        EvStepStart,
        Orchestrator,
    )

    specs = _build_sales_specs()
    print(f"{C_DIM}[scenario] servers={[s.name for s in specs]}{C_RESET}")

    async with MCPManager(specs) as mgr:
        print(f"{C_DIM}[scenario] {len(mgr.tools)} tools registered{C_RESET}")

        cfg = AgentConfig()
        full_exec = AgentLoop(mgr, cfg=cfg)

        if not os.environ.get("ANTHROPIC_API_KEY"):
            print(f"{C_RED}[scenario] ANTHROPIC_API_KEY not set — Planner required{C_RESET}")
            sys.exit(1)

        planner_llm = PlannerLLM()
        catalog = load_catalog()
        semantic_layer = load_semantic_layer()
        workspace_semantic_layer = load_workspace_semantic_layer()
        field_dict = load_field_dict()
        atomic_exec = AtomicExecutor(mcp_manager=mgr, field_dict=field_dict)
        try:
            escalate_exec = EscalateExecutor()
            escalate_info = f" escalate={escalate_exec.cfg.model}"
        except RuntimeError as e:
            logger.warning(f"EscalateExecutor unavailable: {e}")
            escalate_exec = None
            escalate_info = " escalate=off"
        print(
            f"{C_DIM}[scenario] Planner={planner_llm.cfg.model} "
            f"catalog={len(catalog.elementaries)} elementaries "
            f"semantic_layer={semantic_layer.object_count}obj@{semantic_layer.version} "
            f"gw_layer={workspace_semantic_layer.tool_count}tools@{workspace_semantic_layer.version} "
            f"atomic_max_turns={atomic_exec._loop.cfg.max_turns} "
            f"full_max_turns={cfg.max_turns}{escalate_info}{C_RESET}"
        )

        orchestrator = Orchestrator(
            full_executor=full_exec,
            planner_llm=planner_llm,
            catalog=catalog,
            atomic_executor=atomic_exec,
            escalate_executor=escalate_exec,
            semantic_layer=semantic_layer,
            workspace_semantic_layer=workspace_semantic_layer,
        )

        history: list[dict] = []
        for i, turn in enumerate(args.turns, 1):
            print(
                f"\n{C_BOLD}{C_CYAN}════════ Turn {i}/{len(args.turns)} ════════{C_RESET}\n"
                f"{C_CYAN}[User]{C_RESET} {turn}\n"
            )
            collected: list[str] = []
            async for ev in orchestrator.run(turn, history):
                if isinstance(ev, EvPlanCreated):
                    steps_summary = ", ".join(
                        f"{s['mode']}:{s.get('elementary_id') or '—'}" for s in ev.steps
                    )
                    print(
                        f"{C_MAGENTA}[plan]{C_RESET} id={ev.plan_id} "
                        f"class={ev.classification} steps=[{steps_summary}] "
                        f"fallback={ev.fallback}"
                    )
                    if ev.user_intent:
                        print(f"  {C_DIM}intent: {ev.user_intent}{C_RESET}")
                    if ev.synthesis_hint:
                        print(f"  {C_DIM}synthesis_hint: {ev.synthesis_hint}{C_RESET}")
                elif isinstance(ev, EvStepStart):
                    print(
                        f"{C_BLUE}[step start]{C_RESET} {ev.step_id} "
                        f"mode={ev.mode} elem={ev.elementary_id or '—'}"
                    )
                    print(f"  {C_DIM}task: {ev.task_description}{C_RESET}")
                elif isinstance(ev, EvStepEnd):
                    print(
                        f"{C_BLUE}[step end]{C_RESET} {ev.step_id} status={ev.status}"
                    )
                elif isinstance(ev, EvToolCallStart):
                    print(
                        f"{C_YELLOW}→ tool {ev.name}({_fmt_args(ev.arguments)}){C_RESET}"
                    )
                elif isinstance(ev, EvToolCallResult):
                    mark = "✗" if ev.is_error else "✓"
                    color = C_RED if ev.is_error else C_DIM
                    print(f"  {color}{mark} {ev.name}: {ev.result_summary}{C_RESET}")
                elif isinstance(ev, EvAssistantText):
                    print(f"{C_GREEN}[Assistant]{C_RESET} {ev.text}")
                    collected.append(ev.text)
                elif isinstance(ev, EvFinish):
                    print(
                        f"{C_DIM}[finish] reason={ev.reason} turns={ev.turns}{C_RESET}"
                    )
            history.append({"role": "user", "content": turn})
            if collected:
                history.append({"role": "assistant", "content": "\n".join(collected)})
            else:
                history.append({"role": "assistant", "content": "(no reply)"})


if __name__ == "__main__":
    asyncio.run(main())
