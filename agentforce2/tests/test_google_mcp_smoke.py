"""Google Workspace FastMCP サーバーのスモークテスト。

前提:
  config/tokens/google_credentials.json に OAuth client (Desktop app) JSON
  初回実行: ブラウザで OAuth 同意

uv run python -m tests.test_google_mcp_smoke
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

JST = timezone(timedelta(hours=9))


async def main():
    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "mcp_servers.google_mcp"],
        cwd=str(Path(__file__).resolve().parents[1]),
        env={**os.environ},
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            print(f"✅ Tools registered: {len(tools.tools)}")
            for t in tools.tools:
                print(f"  - {t.name}: {(t.description or '').splitlines()[0][:80]}")

            # Calendar list (今日+3日)
            start = datetime.now(JST).replace(hour=0, minute=0, second=0, microsecond=0)
            end = start + timedelta(days=3)
            r = await session.call_tool("calendar_list_events", {
                "start_iso": start.isoformat(), "end_iso": end.isoformat()
            })
            payload = _extract(r)
            print(f"\n✅ calendar_list_events: count={payload.get('count')}")
            for e in (payload.get("events") or [])[:3]:
                print(f"   - {e.get('start')} | {e.get('summary')}")

            # Availability check (明日 10:00-11:00, 14:00-15:00)
            tomorrow = start + timedelta(days=1)
            slot_a = {"start": tomorrow.replace(hour=10).isoformat(), "end": tomorrow.replace(hour=11).isoformat()}
            slot_b = {"start": tomorrow.replace(hour=14).isoformat(), "end": tomorrow.replace(hour=15).isoformat()}
            r = await session.call_tool("calendar_check_availability", {
                "candidate_slots": [slot_a, slot_b]
            })
            payload = _extract(r)
            print(f"\n✅ calendar_check_availability:")
            for s in payload.get("slots", []):
                print(f"   {s['start'][:16]} busy={s['busy']} conflicts={len(s['conflicts'])}")

            print("\n🎉 Smoke test done (Gmail draft skipped - destructive)")


def _extract(result) -> dict:
    for c in result.content:
        if hasattr(c, "text"):
            try:
                return json.loads(c.text)
            except Exception:
                pass
    if getattr(result, "structuredContent", None):
        return result.structuredContent  # type: ignore
    return {}


if __name__ == "__main__":
    asyncio.run(main())
