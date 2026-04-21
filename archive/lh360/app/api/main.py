"""FastAPI アプリケーション定義。

起動:
    cd lh360
    uv run uvicorn app.api.main:app --reload --port 8000
"""
from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI

from .routes import chat, health, profile
from .startup import app_state

load_dotenv()
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger("api.main")

ALLOWED_ORIGINS = {b"http://localhost:5173", b"http://127.0.0.1:5173"}


class RawCORSMiddleware:
    """SSE ストリーミングを壊さない raw ASGI CORS ミドルウェア。

    Starlette の CORSMiddleware / BaseHTTPMiddleware は内部で
    call_next() → body 読み出しを行うため StreamingResponse をバッファする。
    この実装は ASGI の send/receive を直接ラップし、body には一切触らない。
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        origin = b""
        for name, value in scope.get("headers", []):
            if name == b"origin":
                origin = value
                break

        is_allowed = origin in ALLOWED_ORIGINS

        # preflight
        if scope["method"] == "OPTIONS" and is_allowed:
            await send({
                "type": "http.response.start",
                "status": 200,
                "headers": [
                    (b"access-control-allow-origin", origin),
                    (b"access-control-allow-methods", b"GET, POST, PUT, DELETE, OPTIONS"),
                    (b"access-control-allow-headers", b"content-type"),
                    (b"access-control-max-age", b"3600"),
                    (b"content-length", b"0"),
                ],
            })
            await send({"type": "http.response.body", "body": b""})
            return

        if not is_allowed:
            await self.app(scope, receive, send)
            return

        async def send_with_cors(message):
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                headers.append((b"access-control-allow-origin", origin))
                message = {**message, "headers": headers}
            await send(message)

        await self.app(scope, receive, send_with_cors)


@asynccontextmanager
async def lifespan(fastapi_app: FastAPI):
    fastapi_app.state.lh360 = app_state
    await app_state.initialize()
    yield
    await app_state.shutdown()


# FastAPI インスタンス（ルーター登録はここ）
_fastapi = FastAPI(
    title="Local Headless 360 API",
    version="0.1.0",
    lifespan=lifespan,
)
_fastapi.include_router(chat.router)
_fastapi.include_router(health.router)
_fastapi.include_router(profile.router)


# uvicorn が読み込む ASGI app（CORS ラッパ）
app = RawCORSMiddleware(_fastapi)
