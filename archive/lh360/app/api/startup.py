"""アプリ起動時の初期化。

Gradio の _ensure_initialized() を FastAPI lifespan に移植。
MCPManager・AgentLoop・Orchestrator を生成してアプリ state に保持する。
"""
from __future__ import annotations

import asyncio
import logging
import os

from agent.atomic import AtomicExecutor, load_field_dict
from agent.escalate import EscalateExecutor
from agent.loop import AgentConfig, AgentLoop
from agent.mcp_manager import MCPManager
from planner import (
    PlannerLLM,
    load_catalog,
    load_semantic_layer,
    load_workspace_semantic_layer,
)
from planner.orchestrator import Orchestrator

from .mcp_config import current_specs

logger = logging.getLogger("api.startup")


class AppState:
    """プロセス全体で共有するシングルトン状態。"""

    def __init__(self) -> None:
        self.mgr: MCPManager | None = None
        self.orchestrator: Orchestrator | None = None
        self._lock = asyncio.Lock()

    async def initialize(self) -> None:
        async with self._lock:
            if self.mgr is not None:
                return  # 二重初期化防止

            specs = current_specs()
            logger.info(f"Starting MCP manager with: {[s.name for s in specs]}")
            mgr = MCPManager(specs)
            await mgr.__aenter__()
            self.mgr = mgr

            agent = AgentLoop(mgr, cfg=AgentConfig())

            planner_llm = None
            catalog = None
            semantic_layer = None
            workspace_semantic_layer = None

            if os.environ.get("ANTHROPIC_API_KEY"):
                try:
                    planner_llm = PlannerLLM()
                    catalog = load_catalog()
                    semantic_layer = load_semantic_layer()
                    workspace_semantic_layer = load_workspace_semantic_layer()
                    logger.info(
                        f"[planner] Claude Sonnet Planner enabled "
                        f"(model={planner_llm.cfg.model}, "
                        f"catalog={len(catalog.elementaries)} elementaries)"
                    )
                except Exception as e:
                    logger.warning(f"[planner] init failed, falling back to dummy: {e}")
                    planner_llm = catalog = semantic_layer = workspace_semantic_layer = None
            else:
                logger.info("[planner] ANTHROPIC_API_KEY not set; using dummy planner")

            atomic_executor = None
            if planner_llm is not None:
                atomic_executor = AtomicExecutor(mcp_manager=mgr, field_dict=load_field_dict())
                logger.info(f"[atomic] AtomicExecutor enabled")

            escalate_executor = None
            if planner_llm is not None:
                try:
                    escalate_executor = EscalateExecutor()
                    logger.info(f"[escalate] EscalateExecutor enabled (model={escalate_executor.cfg.model})")
                except RuntimeError as e:
                    logger.warning(f"[escalate] init failed, disabled: {e}")

            self.orchestrator = Orchestrator(
                full_executor=agent,
                planner_llm=planner_llm,
                catalog=catalog,
                atomic_executor=atomic_executor,
                escalate_executor=escalate_executor,
                semantic_layer=semantic_layer,
                workspace_semantic_layer=workspace_semantic_layer,
            )
            logger.info("AppState initialized")

    async def shutdown(self) -> None:
        if self.mgr is not None:
            await self.mgr.__aexit__(None, None, None)
            self.mgr = None
            logger.info("MCPManager stopped")

    def tools_by_server(self) -> dict[str, list[str]]:
        if self.mgr is None:
            return {}
        result: dict[str, list[str]] = {}
        for t in self.mgr.tools:
            result.setdefault(t.server, []).append(t.original_name)
        return result


# モジュールレベルのシングルトン（FastAPI app.state に格納）
app_state = AppState()
