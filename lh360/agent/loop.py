"""Agent Loop - OpenAI互換 API (mlx-lm) + Multi-MCP tools。

Gemma 4 の tool calling で並列 tool_calls を活かし、最大 N ターンまで自律実行。

イベント駆動で UI 側に状況を流せるように、`Event` を async generator で yield する。
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, AsyncIterator, Literal

import yaml
from openai import AsyncOpenAI

from .mcp_manager import MCPManager

JST = timezone(timedelta(hours=9))

logger = logging.getLogger("agent.loop")


# ---- Event types for UI ----
@dataclass
class EvAssistantText:
    kind: Literal["assistant_text"] = "assistant_text"
    text: str = ""


@dataclass
class EvToolCallStart:
    kind: Literal["tool_call_start"] = "tool_call_start"
    id: str = ""
    name: str = ""
    arguments: dict = field(default_factory=dict)


@dataclass
class EvToolCallResult:
    kind: Literal["tool_call_result"] = "tool_call_result"
    id: str = ""
    name: str = ""
    result_summary: str = ""
    is_error: bool = False


@dataclass
class EvFinish:
    kind: Literal["finish"] = "finish"
    reason: str = "stop"
    turns: int = 0


Event = EvAssistantText | EvToolCallStart | EvToolCallResult | EvFinish


@dataclass
class AgentConfig:
    # env は instantiation 時に読む（load_dotenv() 後でも反映されるように default_factory 使用）
    base_url: str = field(default_factory=lambda: os.environ.get("MLX_BASE_URL", "http://127.0.0.1:8080/v1"))
    model: str = field(default_factory=lambda: os.environ.get("MLX_MODEL", "mlx-community/gemma-4-26b-a4b-it-4bit"))
    api_key: str = field(default_factory=lambda: os.environ.get("MLX_API_KEY", "not-needed"))
    max_turns: int = field(default_factory=lambda: int(os.environ.get("AGENT_MAX_TURNS", "8")))
    # Gemma 4 は thinking tokens を消費するので max_tokens は広めに確保する
    # (mlx-lm の default は ~500 だが、system prompt + tool schema が長いと
    # thinking phase で使い切って finish_reason='length' で空応答になる)
    max_tokens: int = field(default_factory=lambda: int(os.environ.get("AGENT_MAX_TOKENS", "4096")))
    temperature: float = 0.1
    timeout_sec: float = field(default_factory=lambda: float(os.environ.get("AGENT_TIMEOUT_SEC", "120")))
    # tool_call 崩壊時のリトライ温度列（初回を除くリトライ分のみ）。
    # サンプリングゆらぎ由来（Gemma 4 の失敗分類 ⑤）の崩壊を拾う狙い。
    # ②③ の能力不足には効かない前提で、リトライ回数は控えめに。
    retry_temperatures: tuple[float, ...] = (0.5, 0.8)


class AgentLoop:
    def __init__(self, mcp_manager: MCPManager, cfg: AgentConfig | None = None,
                 system_prompt: str | None = None):
        self.mcp = mcp_manager
        self.cfg = cfg or AgentConfig()
        self.system_prompt = system_prompt or _load_default_system_prompt()
        self.client = AsyncOpenAI(
            base_url=self.cfg.base_url, api_key=self.cfg.api_key, timeout=self.cfg.timeout_sec
        )

    async def _generate_with_retry(self, messages: list[dict], tools: list[dict]):
        """tool_call 完全崩壊時のみ temperature を上げて再試行する。

        Gemma 4 の失敗分類 ⑤（サンプリングゆらぎ）を拾う狙い。
        ②③（reasoning/self-correction の能力不足）には効かない前提で、
        `retry_temperatures` は控えめ（2 段階）。
        崩壊試行は履歴に残さない（messages を改変しない）。

        戻り値: OpenAI ChatCompletion の choice オブジェクト（成功 or 最終試行）。
        """
        temps = [self.cfg.temperature, *self.cfg.retry_temperatures]
        last_choice = None
        for attempt, temp in enumerate(temps):
            resp = await self.client.chat.completions.create(
                model=self.cfg.model,
                messages=messages,
                tools=tools,
                tool_choice="auto",
                temperature=temp,
                parallel_tool_calls=True,
                max_tokens=self.cfg.max_tokens,
            )
            choice = resp.choices[0]
            last_choice = choice
            if not _is_broken_tool_call(choice):
                if attempt > 0:
                    logger.info(
                        f"[retry_success] recovered on attempt {attempt+1}/{len(temps)} "
                        f"at temperature={temp}"
                    )
                return choice
            logger.warning(
                f"[tool_call_format_broken] attempt {attempt+1}/{len(temps)} "
                f"temperature={temp} finish_reason={choice.finish_reason} "
                f"content={choice.message.content!r} tool_calls={choice.message.tool_calls!r}"
            )
        logger.error(
            f"[retry_exhausted] all {len(temps)} attempts produced broken tool_calls. "
            f"temperatures tried: {temps}"
        )
        return last_choice

    async def run(
        self,
        user_message: str,
        history: list[dict] | None = None,
        allowed_tools: set[str] | None = None,
    ) -> AsyncIterator[Event]:
        """ユーザ発話を受けて、tool_call を解決しながら回答に到達するまで loop。

        history: 直前の会話履歴（OpenAI messages 形式）。
        allowed_tools: None なら全 tool 開放。set が指定された場合は
            qualified_name (`<server>__<tool>`) がその集合に含まれる tool のみ
            Gemma に提示する。atomic モード（Planner から絞り込んだ少数 tool だけで
            実行したいケース、Gemma 4 の 25 tool 崩壊閾値対策）で使う。
        """
        messages: list[dict] = []
        # ベース system prompt + 動的プロファイル/時刻を毎ターン注入
        dynamic_ctx = _build_dynamic_context()
        full_system = self.system_prompt + "\n\n" + dynamic_ctx
        messages.append({"role": "system", "content": full_system})
        if history:
            messages.extend(history)
        messages.append({"role": "user", "content": user_message})

        tools = self.mcp.to_openai_tools()
        if allowed_tools is not None:
            before = len(tools)
            tools = [
                t for t in tools
                if t.get("function", {}).get("name") in allowed_tools
            ]
            logger.info(
                f"[allowed_tools] filtered {before} -> {len(tools)} "
                f"(allowed={sorted(allowed_tools)})"
            )

        for turn in range(self.cfg.max_turns):
            logger.info(f"-- turn {turn+1}/{self.cfg.max_turns} --")
            choice = await self._generate_with_retry(messages, tools)
            msg = choice.message

            # assistant テキスト
            if msg.content:
                yield EvAssistantText(text=msg.content)

            # tool_calls があれば実行
            tool_calls = msg.tool_calls or []
            if not tool_calls:
                if turn == 0:
                    logger.warning(
                        f"[no_tool_on_first_turn] finish_reason={choice.finish_reason!r} "
                        f"content_len={len(msg.content or '')} "
                        f"content_preview={(msg.content or '')[:400]!r}"
                    )
                yield EvFinish(reason=choice.finish_reason or "stop", turns=turn + 1)
                return

            # assistant メッセージを履歴に積む (tool_calls必須)
            messages.append({
                "role": "assistant",
                "content": msg.content or "",
                "tool_calls": [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        },
                    }
                    for tc in tool_calls
                ],
            })

            # 並列実行
            async def _exec_one(tc):
                args_raw = tc.function.arguments or "{}"
                try:
                    args = json.loads(args_raw) if isinstance(args_raw, str) else args_raw
                except json.JSONDecodeError as e:
                    return tc, {"error": f"invalid JSON args: {e}", "raw": args_raw}, True
                try:
                    r = await self.mcp.call_tool(tc.function.name, args or {})
                    text_parts = []
                    for c in r.content:
                        if hasattr(c, "text"):
                            text_parts.append(c.text)
                    text = "\n".join(text_parts) or "(no text content)"
                    return tc, text, bool(getattr(r, "isError", False))
                except Exception as e:
                    logger.exception(f"tool {tc.function.name} failed")
                    return tc, {"error": str(e)}, True

            # UI 通知（並列）
            for tc in tool_calls:
                try:
                    args_preview = json.loads(tc.function.arguments or "{}")
                except Exception:
                    args_preview = {"_raw": tc.function.arguments}
                yield EvToolCallStart(id=tc.id, name=tc.function.name, arguments=args_preview)

            results = await asyncio.gather(*[_exec_one(tc) for tc in tool_calls])

            for tc, result, is_err in results:
                content_str = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": content_str,
                })
                if is_err:
                    logger.warning(
                        f"[tool_error] {tc.function.name} args={tc.function.arguments!r} "
                        f"result={content_str[:500]!r}"
                    )
                else:
                    logger.info(
                        f"[tool_ok] {tc.function.name} args={tc.function.arguments!r} "
                        f"→ {content_str[:200]!r}"
                    )
                summary = content_str[:200] + ("…" if len(content_str) > 200 else "")
                yield EvToolCallResult(
                    id=tc.id, name=tc.function.name,
                    result_summary=summary, is_error=is_err,
                )

        logger.warning(
            f"[max_turns] exhausted {self.cfg.max_turns} turns without finishing — "
            f"increase AGENT_ATOMIC_MAX_TURNS / AGENT_MAX_TURNS if this recurs"
        )
        yield EvFinish(reason="max_turns", turns=self.cfg.max_turns)


def _is_broken_tool_call(choice) -> bool:
    """完全崩壊判定: finish_reason=tool_calls と主張しているのに tool_calls が空。

    Gemma 4 でサンプリングゆらぎにより tool_call フォーマットが壊れると、
    サーバ側は `finish_reason=tool_calls` を返すが構造化された tool_calls は
    パースできず None/空になる。これを崩壊とみなしてリトライ対象にする。
    """
    if choice.finish_reason != "tool_calls":
        return False
    tcs = getattr(choice.message, "tool_calls", None)
    return not tcs


def _load_default_system_prompt() -> str:
    p = Path(__file__).resolve().parents[1] / "prompts" / "system_base.md"
    return p.read_text(encoding="utf-8")


def _build_dynamic_context() -> str:
    """毎ターン注入: 現在日時 / SSoT identity / 担当者 identity のみ。

    base プロンプトは汎用で、デプロイ固有情報（SSoT 名称・担当者名）を持たない。
    このコンテキストがそれを補う最小限の接続点。
    スケジュール固有のデータ（勤務場所・営業時間等）は base の関知外。
    """
    now_jst = datetime.now(JST)
    wd_map = ["月", "火", "水", "木", "金", "土", "日"]
    ctx = [
        "## 現在日時（JST）",
        f"- {now_jst.strftime('%Y-%m-%d %H:%M')} ({wd_map[now_jst.weekday()]}曜日)",
    ]

    # SSoT identity (デプロイごとの System of Record)
    env_path = Path(os.environ.get(
        "ENVIRONMENT_CONFIG_PATH",
        Path(__file__).resolve().parents[1] / "config" / "environment.yaml",
    ))
    if env_path.exists():
        try:
            env = yaml.safe_load(env_path.read_text(encoding="utf-8")) or {}
            ssot = env.get("ssot") or {}
            if ssot.get("name"):
                ctx.append("")
                ctx.append("## このセッションの SSoT")
                ctx.append(f"- 名称: {ssot['name']}")
                if ssot.get("tool_prefix"):
                    ctx.append(f"- ツール prefix: `{ssot['tool_prefix']}__*`")
                if ssot.get("domains"):
                    ctx.append(f"- 管轄ドメイン（ヒント）: {ssot['domains']}")
        except Exception as e:
            logger.warning(f"failed to load environment.yaml: {e}")

    # 担当者 identity (エージェントが支援する相手)
    profile_path = Path(os.environ.get(
        "USER_PROFILE_PATH",
        Path(__file__).resolve().parents[1] / "config" / "user_profile.yaml",
    ))
    if profile_path.exists():
        try:
            p = yaml.safe_load(profile_path.read_text(encoding="utf-8")) or {}
            u = p.get("user") or {}
            if u.get("name"):
                ctx.append("")
                ctx.append("## あなたが支援する担当者")
                ctx.append(f"- 氏名: {u['name']}")
                if u.get("role"):
                    ctx.append(f"- 役職: {u['role']}")
                if u.get("email"):
                    ctx.append(f"- メール: {u['email']}")
        except Exception as e:
            logger.warning(f"failed to load user_profile.yaml: {e}")

    return "\n".join(ctx)
