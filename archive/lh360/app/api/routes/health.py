"""GET /health — 接続状態チェック。"""
from __future__ import annotations

import os
from pathlib import Path

import httpx
from fastapi import APIRouter
from fastapi.requests import Request

from agent.loop import AgentConfig
from ..mcp_config import ROOT, google_creds_ok, sf_username

router = APIRouter()


def _probe_mlx(base_url: str) -> bool:
    try:
        r = httpx.get(f"{base_url}/models", timeout=2)
        return r.status_code == 200
    except Exception:
        return False


@router.get("/health")
async def health(request: Request):
    cfg = AgentConfig()
    state = request.app.state.lh360
    tools = state.tools_by_server() if state.mgr else {}

    return {
        "mlx": {
            "ok": _probe_mlx(cfg.base_url),
            "url": cfg.base_url,
            "model": cfg.model,
        },
        "salesforce": {
            "ok": sf_username() is not None,
            "username": sf_username(),
        },
        "google": {
            "ok": google_creds_ok(),
        },
        "mcp": {
            "initialized": state.mgr is not None,
            "tools": tools,
        },
    }
