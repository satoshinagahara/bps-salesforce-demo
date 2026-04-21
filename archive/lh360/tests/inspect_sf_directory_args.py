"""Salesforce MCP の各ツールの schema を走査し、`directory` 引数を要求するものを列挙する。

α(1)「directory 絶対パス問題」対処の第一歩として、どこに対処を入れるべきか把握する。
"""
from __future__ import annotations

import asyncio
import json
import sys
from app.api.mcp_config import current_specs as _current_specs
from agent.mcp_manager import MCPManager


async def main() -> None:
    # sales プロファイルで起動（sf は必ず含まれる）
    specs = [s for s in _current_specs() if s.name == "sf"]
    if not specs:
        print("sf MCP not available (sf-config.json missing?)", file=sys.stderr)
        sys.exit(1)

    async with MCPManager(specs) as mgr:
        hits: list[dict] = []
        for t in mgr.tools:
            props = (t.input_schema or {}).get("properties") or {}
            if "directory" in props:
                hits.append({
                    "name": t.original_name,
                    "qualified": t.qualified_name,
                    "directory_schema": props["directory"],
                    "required": (t.input_schema or {}).get("required") or [],
                    "description": (t.description or "")[:200],
                })
        print(f"Total sf tools: {len(mgr.tools)}")
        print(f"Tools with 'directory' param: {len(hits)}")
        print("=" * 80)
        for h in hits:
            print(json.dumps(h, ensure_ascii=False, indent=2))
            print("-" * 80)


if __name__ == "__main__":
    asyncio.run(main())
