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

    argument_defaults:
        このサーバ配下の全ツールに対して、呼び出し時に引数を補正するための既定値。
        ツールの input_schema.properties にそのキーが定義されていて、かつ LLM が
        (a) 値を渡さなかった / (b) 空文字を渡した / (c) 相対パス（`.`, `..`, `./..`,
        `../..`）を渡した場合に、この既定値で上書きする。絶対パス等の正しい値が
        渡された場合は尊重する。
        例: sf MCP の `directory` は絶対パス必須だが Gemma 4 は "." を渡しがち。

    argument_overrides:
        このサーバ配下の全ツールに対して、**LLM の指定を無視して常に強制上書き**
        する値。「そもそも LLM に判断させる余地が無い」パラメータ用。
        例: sf MCP を `--orgs <user>` で単一 org 限定起動している場合、
        `usernameOrAlias` は常にその user で固定したい（LLM に選ばせる意味が無く、
        ハルシネーションでレスポンス本文を丸ごと詰めるような失敗を防げる）。
    """
    name: str
    module: str | None = None              # 自作 Python モジュールの場合
    command: str | None = None             # 外部コマンド（uvx/npx/node 等）
    args: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    argument_defaults: dict[str, Any] = field(default_factory=dict)
    argument_overrides: dict[str, Any] = field(default_factory=dict)


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
        # server名 → argument_defaults / argument_overrides のインデックス
        self._arg_defaults: dict[str, dict[str, Any]] = {
            s.name: dict(s.argument_defaults) for s in specs if s.argument_defaults
        }
        self._arg_overrides: dict[str, dict[str, Any]] = {
            s.name: dict(s.argument_overrides) for s in specs if s.argument_overrides
        }

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
        arguments = self._apply_argument_policies(entry, arguments)
        session = self._sessions[entry.server]
        result = await session.call_tool(entry.original_name, arguments)
        return result

    def _apply_argument_policies(self, entry: ToolEntry, arguments: dict) -> dict:
        """spec.argument_overrides / argument_defaults をツール引数に適用する。

        順序:
          1. **overrides**: LLM の指定を無視して強制上書き（デプロイ固有の固定値）
          2. **defaults**: 値が無効（未指定 / "." / "./..." 等）の時のみ既定値で補完

        どちらもツールの input_schema.properties に該当キーがある場合のみ適用。
        存在しないキーを混入させない（サーバが unknown arg エラーを返すのを防ぐ）。
        """
        overrides = self._arg_overrides.get(entry.server) or {}
        defaults = self._arg_defaults.get(entry.server) or {}
        if not overrides and not defaults:
            return arguments
        props = (entry.input_schema or {}).get("properties") or {}
        if not props:
            return arguments
        corrected = dict(arguments) if arguments else {}

        # 1. unconditional overrides
        for key, forced_value in overrides.items():
            if key not in props:
                continue
            cur = corrected.get(key, _MISSING)
            if cur is _MISSING or cur != forced_value:
                logger.info(
                    f"[arg_override] {entry.qualified_name}: {key}={_preview(cur)} → {forced_value!r}"
                )
            corrected[key] = forced_value

        # 2. conditional defaults
        for key, default_value in defaults.items():
            if key not in props:
                continue
            if key in overrides:
                continue  # overrides が既に処理済み
            value = corrected.get(key, _MISSING)
            if _should_override(value):
                logger.info(
                    f"[arg_default] {entry.qualified_name}: {key}={value!r} → {default_value!r}"
                )
                corrected[key] = default_value
        return corrected


# 「キー未指定」を None と区別するためのセンチネル
_MISSING = object()


def _preview(value: Any, limit: int = 80) -> str:
    """ログ出力用の短い repr（LLM が散文を詰めてきた場合にログが肥大化しないよう）。"""
    if value is _MISSING:
        return "<missing>"
    s = repr(value)
    if len(s) > limit:
        s = s[: limit - 1] + "…"
    return s


def _should_override(value: Any) -> bool:
    """spec.argument_defaults の上書き判定。

    True を返すケース（= LLM が意味のある値を渡せていない）:
      - そもそもキーが指定されていない（_MISSING）
      - None
      - 空文字 / 空白のみ
      - "." / ".." / "./..." / "../..." のような相対パス表記
      - 非 str 型（list/dict 等、このデフォルト適用対象のキーは基本 str 想定）
    """
    if value is _MISSING or value is None:
        return True
    if not isinstance(value, str):
        return True
    stripped = value.strip()
    if not stripped:
        return True
    if stripped in (".", ".."):
        return True
    if stripped.startswith("./") or stripped.startswith("../"):
        return True
    return False
