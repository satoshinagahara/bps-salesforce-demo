"""Multi-MCP Manager.

複数の FastMCP サーバを stdio で起動し、ツール一覧を統合して公開する。
ツール名は衝突回避のため `<server>__<tool>` 形式にリネーム（OpenAI schema対応）。
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys
from contextlib import AsyncExitStack
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from mcp import ClientSession, StdioServerParameters, types
from mcp.client.stdio import stdio_client

logger = logging.getLogger("mcp_manager")


@dataclass
class MCPServerSpec:
    """MCP サーバの起動設定。

    起動方法は 2 種類:
      1. **Python モジュール** (自作 FastMCP 用):
         `MCPServerSpec(name="gw", module="mcp_servers.google_mcp")`
         → `sys.executable -m mcp_servers.google_mcp` で起動
      2. **任意コマンド** (公式 MCP サーバ uvx / npx 等):
         `MCPServerSpec(name="fetch", command="uvx", args=["mcp-server-fetch"])`
         `MCPServerSpec(name="sf", command="npx", args=["-y", "@salesforce/mcp", "--orgs", "username"])`
    """
    name: str
    module: str | None = None              # 自作 Python モジュールの場合
    command: str | None = None             # 外部コマンド（uvx/npx/node 等）
    args: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)


@dataclass
class ToolEntry:
    server: str
    original_name: str
    qualified_name: str                    # f"{server}__{original_name}"
    description: str
    input_schema: dict


class MCPManager:
    """AsyncExitStack でセッションの生存期間を管理。"""

    def __init__(self, specs: list[MCPServerSpec], cwd: str | None = None):
        self.specs = specs
        self.cwd = cwd or str(Path(__file__).resolve().parents[1])
        self._stack: AsyncExitStack | None = None
        self._sessions: dict[str, ClientSession] = {}
        self._tools: list[ToolEntry] = []

    async def __aenter__(self):
        self._stack = AsyncExitStack()
        await self._stack.__aenter__()
        for spec in self.specs:
            try:
                if spec.command:
                    cmd, args = spec.command, spec.args
                elif spec.module:
                    cmd, args = sys.executable, ["-m", spec.module]
                else:
                    raise ValueError(
                        f"MCPServerSpec '{spec.name}': either 'command' or 'module' must be set"
                    )
                params = StdioServerParameters(
                    command=cmd,
                    args=args,
                    cwd=self.cwd,
                    env={**os.environ, **spec.env},
                )
                read, write = await self._stack.enter_async_context(stdio_client(params))
                session = await self._stack.enter_async_context(ClientSession(read, write))
                await session.initialize()
                self._sessions[spec.name] = session

                tools = (await session.list_tools()).tools
                for t in tools:
                    self._tools.append(ToolEntry(
                        server=spec.name,
                        original_name=t.name,
                        qualified_name=f"{spec.name}__{t.name}",
                        description=t.description or "",
                        input_schema=t.inputSchema or {"type": "object", "properties": {}},
                    ))
                logger.info(f"✅ MCP '{spec.name}': {len(tools)} tools")
            except Exception as e:
                logger.error(f"❌ MCP '{spec.name}' failed to start: {e}")
                raise
        return self

    async def __aexit__(self, exc_type, exc, tb):
        if self._stack:
            await self._stack.__aexit__(exc_type, exc, tb)
        self._stack = None
        self._sessions.clear()
        self._tools.clear()

    @property
    def tools(self) -> list[ToolEntry]:
        return self._tools

    def to_openai_tools(self) -> list[dict]:
        """OpenAI ChatCompletion 用の tools schema に変換。"""
        return [
            {
                "type": "function",
                "function": {
                    "name": t.qualified_name,
                    "description": t.description,
                    "parameters": t.input_schema,
                },
            }
            for t in self._tools
        ]

    async def call_tool(self, qualified_name: str, arguments: dict) -> Any:
        entry = next((t for t in self._tools if t.qualified_name == qualified_name), None)
        if entry is None:
            raise ValueError(f"Unknown tool: {qualified_name}")
        session = self._sessions[entry.server]
        result = await session.call_tool(entry.original_name, arguments)
        return result
