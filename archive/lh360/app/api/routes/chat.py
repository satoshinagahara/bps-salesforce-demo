"""POST /chat — SSE ストリームでエージェント応答を返す。

Orchestrator から流れる全イベントを JSON SSE に変換して送出する。
Gradio では logger.debug で捨てていた EvPlanCreated / EvStepStart / EvStepEnd も
ここで初めて UI に届く。

SSE イベント種別:
  plan_created   — Planner がプランを生成（steps 一覧含む）
  step_start     — ステップ開始（mode / elementary_id）
  step_end       — ステップ完了
  tool_start     — tool 呼び出し開始（name / arguments）
  tool_result    — tool 呼び出し結果（result_summary / is_error）
  text           — アシスタントテキストチャンク
  finish         — 完了
  error          — エラー
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import asdict
from typing import Any, AsyncIterator

from fastapi import APIRouter, HTTPException
from fastapi.requests import Request
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from agent.loop import (
    EvAssistantText,
    EvFinish,
    EvToolCallResult,
    EvToolCallStart,
)
from planner.orchestrator import EvPlanCreated, EvStepEnd, EvStepStart

logger = logging.getLogger("api.chat")

router = APIRouter()

EXAMPLES = [
    "今四半期の優先商談トップ3を教えて",
    "今四半期で一番優先すべき商談を1つ選んで、その取引先責任者の連絡先と住所を教えて",
    "明日・明後日の商談アポに空き時間はある？",
    "最優先商談の取引先責任者にアポを取るための候補日時を3つ提案して",
]


class ChatRequest(BaseModel):
    message: str
    history: list[dict[str, str]] = []


def _ev_to_sse(ev: Any, tool_start_times: dict[str, float]) -> tuple[str, dict] | None:
    """Orchestrator イベント → (event_name, data_dict)。None なら送出スキップ。"""

    if isinstance(ev, EvPlanCreated):
        return "plan_created", {
            "plan_id": ev.plan_id,
            "user_intent": ev.user_intent,
            "classification": ev.classification,
            "steps": ev.steps,
            "synthesis_hint": ev.synthesis_hint,
            "fallback": ev.fallback,
        }

    if isinstance(ev, EvStepStart):
        return "step_start", {
            "step_id": ev.step_id,
            "mode": ev.mode,
            "elementary_id": ev.elementary_id,
            "task_description": ev.task_description,
        }

    if isinstance(ev, EvStepEnd):
        return "step_end", {
            "step_id": ev.step_id,
            "status": ev.status,
            "summary": ev.summary,
        }

    if isinstance(ev, EvToolCallStart):
        tool_start_times[ev.id] = time.time()
        return "tool_start", {
            "id": ev.id,
            "name": ev.name,
            "arguments": ev.arguments,
        }

    if isinstance(ev, EvToolCallResult):
        elapsed = time.time() - tool_start_times.pop(ev.id, time.time())
        return "tool_result", {
            "id": ev.id,
            "name": ev.name,
            "result_summary": ev.result_summary,
            "is_error": ev.is_error,
            "elapsed": round(elapsed, 2),
        }

    if isinstance(ev, EvAssistantText):
        return "text", {"text": ev.text}

    if isinstance(ev, EvFinish):
        return "finish", {}

    return None  # 未知イベントはスキップ


async def _stream(request: Request, message: str, history: list[dict]) -> AsyncIterator[dict]:
    state = request.app.state.lh360
    if state.orchestrator is None:
        yield {"event": "error", "data": json.dumps({"message": "Not initialized"})}
        return

    tool_start_times: dict[str, float] = {}

    try:
        async for ev in state.orchestrator.run(message, history):
            result = _ev_to_sse(ev, tool_start_times)
            if result is None:
                continue
            event_name, data = result
            yield {"event": event_name, "data": json.dumps(data, ensure_ascii=False)}

    except Exception as e:
        logger.exception(f"Stream error: {e}")
        yield {"event": "error", "data": json.dumps({"message": str(e)})}


@router.post("/chat")
async def chat(req: ChatRequest, request: Request):
    if not req.message.strip():
        raise HTTPException(status_code=400, detail="message is empty")

    # history のフォーマットを Orchestrator が期待する形に正規化
    history = [
        {"role": h["role"], "content": h["content"]}
        for h in req.history
        if h.get("role") in ("user", "assistant") and h.get("content")
    ]

    return EventSourceResponse(_stream(request, req.message, history))


@router.get("/chat/examples")
async def chat_examples():
    return {"examples": EXAMPLES}
