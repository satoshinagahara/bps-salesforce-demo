"""Planner LLM ラッパ (Claude Sonnet)。

Phase α-3 で使う Planner 推論の入り口。
- Plan 生成: JSON 出力を期待する single-turn chat
- Synthesis: 最終回答合成 (stream 対応)
- システムプロンプトは prompts/ から読み込む

モデル選定根拠: docs/concepts/lh360-plan-executor-reframing.md §追加議論 C。
β catalog (~20k tokens) を意味論的に使いこなすには Sonnet クラスが必要。

【環境変数】
- ANTHROPIC_API_KEY: API キー (必須)
- LH360_PLANNER_MODEL: モデル ID (既定: claude-sonnet-4-6)
"""
from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator

from anthropic import AsyncAnthropic, APIError


logger = logging.getLogger("planner.llm")

DEFAULT_MODEL = "claude-sonnet-4-6"
PROMPTS_DIR = Path(__file__).resolve().parent / "prompts"


@dataclass
class PlannerLLMConfig:
    model: str = ""
    api_key: str | None = None
    max_tokens_plan: int = 2000
    max_tokens_synthesis: int = 4000
    timeout_sec: float = 60.0

    def __post_init__(self):
        if not self.model:
            self.model = os.environ.get("LH360_PLANNER_MODEL", DEFAULT_MODEL)
        if self.api_key is None:
            self.api_key = os.environ.get("ANTHROPIC_API_KEY")


class PlannerLLM:
    """Claude Sonnet を叩く薄いラッパ。"""

    def __init__(self, cfg: PlannerLLMConfig | None = None):
        self.cfg = cfg or PlannerLLMConfig()
        if not self.cfg.api_key:
            raise RuntimeError(
                "ANTHROPIC_API_KEY is not set. Planner LLM requires it to run."
            )
        self.client = AsyncAnthropic(api_key=self.cfg.api_key, timeout=self.cfg.timeout_sec)

    # ---- system prompt loader ----
    @staticmethod
    def load_prompt(name: str) -> str:
        p = PROMPTS_DIR / f"{name}.md"
        if not p.exists():
            raise FileNotFoundError(p)
        return p.read_text(encoding="utf-8")

    # ---- Plan generation ----
    async def generate_plan_json(
        self,
        system_prompt: str,
        user_prompt: str,
    ) -> dict:
        """Plan を JSON で生成する。

        Claude は出力前後に地の文を付けがちなので、JSON ブロックを robust に抽出する。
        失敗時は例外を投げる (呼び出し側で fallback 発動)。

        システムプロンプト (β catalog + planner 指示 ~17KB) は ephemeral cache に載せる。
        同じ prompt が 5 分以内に再利用されれば入力料が ~0.1× になる。
        """
        try:
            resp = await self.client.messages.create(
                model=self.cfg.model,
                max_tokens=self.cfg.max_tokens_plan,
                system=[{
                    "type": "text",
                    "text": system_prompt,
                    "cache_control": {"type": "ephemeral"},
                }],
                messages=[{"role": "user", "content": user_prompt}],
            )
        except APIError as e:
            logger.error(f"Anthropic API error during plan generation: {e}")
            raise

        _log_cache_usage("plan", resp.usage)

        text = "".join(
            block.text for block in resp.content if getattr(block, "type", None) == "text"
        ).strip()
        logger.debug(f"[planner.raw] {text[:500]}")

        data = _extract_json_object(text)
        if data is None:
            raise ValueError(f"planner did not return valid JSON object: {text[:300]!r}")
        return data

    # ---- Synthesis (streaming) ----
    async def synthesize_stream(
        self,
        system_prompt: str,
        user_prompt: str,
    ) -> AsyncIterator[str]:
        """最終回答を synthesize。text delta を順次 yield する。

        system は ephemeral cache に載せる。synthesis は system 内容が plan と別なので
        cache は plan と synthesis で独立に作られる (同じ system を再利用すれば hit)。
        """
        try:
            async with self.client.messages.stream(
                model=self.cfg.model,
                max_tokens=self.cfg.max_tokens_synthesis,
                system=[{
                    "type": "text",
                    "text": system_prompt,
                    "cache_control": {"type": "ephemeral"},
                }],
                messages=[{"role": "user", "content": user_prompt}],
            ) as stream:
                async for chunk in stream.text_stream:
                    yield chunk
                # 最終 message から usage を取り出してログ出す
                try:
                    final = await stream.get_final_message()
                    _log_cache_usage("synthesis", final.usage)
                except Exception as e:  # 取得失敗しても synth 本体は成功しているので warn 止まり
                    logger.warning(f"failed to fetch final usage for synthesis: {e}")
        except APIError as e:
            logger.error(f"Anthropic API error during synthesis: {e}")
            raise


# ---- cache usage logging ----
def _log_cache_usage(stage: str, usage: Any) -> None:
    """usage から cache hit/miss を抜き出して INFO ログに出す。

    usage には以下のフィールドが載る想定:
    - input_tokens: 非 cache の通常入力トークン
    - cache_creation_input_tokens: cache 書き込み (初回、1.25x 課金)
    - cache_read_input_tokens: cache ヒット (0.1x 課金)
    - output_tokens
    """
    if usage is None:
        return
    inp = getattr(usage, "input_tokens", 0) or 0
    cw = getattr(usage, "cache_creation_input_tokens", 0) or 0
    cr = getattr(usage, "cache_read_input_tokens", 0) or 0
    out = getattr(usage, "output_tokens", 0) or 0
    total_in = inp + cw + cr
    hit = (cr / total_in * 100.0) if total_in > 0 else 0.0
    logger.info(
        f"[cache/{stage}] in={inp} cache_write={cw} cache_read={cr} "
        f"out={out} (hit={hit:.0f}%)"
    )


# ---- helpers ----
_JSON_FENCE_RE = re.compile(r"```(?:json)?\s*\n(.*?)\n```", re.DOTALL)


def _extract_json_object(text: str) -> dict | None:
    """text の中から JSON object を抽出して parse する。

    - コードフェンス内優先 (```json ... ```)
    - なければ最初の `{` から最後の `}` までを試す
    """
    # 1. コードフェンス内
    m = _JSON_FENCE_RE.search(text)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass

    # 2. 地の文中の JSON
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        candidate = text[start : end + 1]
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            pass

    return None
