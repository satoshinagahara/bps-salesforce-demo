"""Escalate Executor — F パターンタスクを Claude Sonnet にオフロードする。

Phase α-5 で追加。Planner が `mode="escalate"` を指定した step の実行経路。

【位置付け】

β カタログで pattern=F とタグされた「深い推論・抽象判断」系タスク (評価・骨格
設計・マッチング等) は、ローカル Gemma 4 26B では品質・一貫性が取れない。
γ 設計で決めた通り、これらは Claude Sonnet に専用プロンプトで投げる。

【full/atomic Executor との違い】

- MCP tool を**呼ばない** (Sonnet への text 生成のみ)
- 構造化 JSON 出力を強制 (schema は f_type ごとにテンプレ側で定義)
- history は持たない (ステートレス)
- 返り値は JSON をパースしたオブジェクトではなく、**Planner に見せる自然文サマリ**

【Stage 2 スコープ (γ 設計 §9)】

- 対応 f_type: **T1 / T2 / T3 / T4 / T5 / T6** の 6 型全て (32 件 / 97% カバー)
- return_mode: assist のみ (overflow は UI 変更が必要なため未対応)
- Masking: OFF (デモ org、個人所有データ前提)
- Pre-router: なし (Planner がどの step を escalate するか判断するため)

設計: docs/in-progress/lh360-f-pattern-cloud-offload-design.md
"""
from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, AsyncIterator, Literal

from anthropic import APIError, AsyncAnthropic

from .loop import EvAssistantText, EvFinish, Event


logger = logging.getLogger("agent.escalate")

PROMPTS_DIR = Path(__file__).resolve().parents[1] / "prompts" / "f_types"

SUPPORTED_F_TYPES = ("T1", "T2", "T3", "T4", "T5", "T6")
"""Stage 2 で全 6 型対応。"""

FTypeLiteral = Literal["T1", "T2", "T3", "T4", "T5", "T6"]


# ---- template metadata ----
@dataclass
class FTypeTemplate:
    """f_type ごとのプロンプトテンプレート情報。"""

    f_type: str
    filename: str  # 例: "t1_opportunity_eval.md"
    required_fields: tuple[str, ...]
    """user prompt に差し込むべきフィールド名 (Planner が context に入れて渡す)。"""


F_TYPE_TEMPLATES: dict[str, FTypeTemplate] = {
    "T1": FTypeTemplate(
        f_type="T1",
        filename="t1_opportunity_eval.md",
        required_fields=("task_description", "candidates", "criteria", "context_data"),
    ),
    "T2": FTypeTemplate(
        f_type="T2",
        filename="t2_hypothesis_generation.md",
        required_fields=("task_description", "observations", "context_data"),
    ),
    "T3": FTypeTemplate(
        f_type="T3",
        filename="t3_skeleton_design.md",
        required_fields=("task_description", "goal", "audience", "constraints", "references"),
    ),
    "T4": FTypeTemplate(
        f_type="T4",
        filename="t4_matching.md",
        required_fields=("task_description", "candidates", "requirements", "context_data"),
    ),
    "T5": FTypeTemplate(
        f_type="T5",
        filename="t5_risk_assessment.md",
        required_fields=("task_description", "target", "standard", "context_data"),
    ),
    "T6": FTypeTemplate(
        f_type="T6",
        filename="t6_mapping.md",
        required_fields=("task_description", "entities", "dimensions", "context_data"),
    ),
}


# ---- config ----
@dataclass
class EscalateConfig:
    model: str = field(
        default_factory=lambda: os.environ.get("LH360_ESCALATE_MODEL", "claude-sonnet-4-6")
    )
    api_key: str | None = field(
        default_factory=lambda: os.environ.get("ANTHROPIC_API_KEY")
    )
    max_tokens: int = 4000
    timeout_sec: float = 90.0


# ---- executor ----
class EscalateExecutor:
    """F パターン専用の Executor。Planner から `mode="escalate"` の step を受ける。"""

    def __init__(self, cfg: EscalateConfig | None = None):
        self.cfg = cfg or EscalateConfig()
        if not self.cfg.api_key:
            raise RuntimeError(
                "ANTHROPIC_API_KEY is not set. EscalateExecutor requires it."
            )
        self.client = AsyncAnthropic(
            api_key=self.cfg.api_key, timeout=self.cfg.timeout_sec
        )
        self._system_prompt: str | None = None
        self._templates: dict[str, str] = {}

    # ---- public entry ----
    async def run(
        self,
        task_description: str,
        context: dict[str, Any] | None = None,
        success_criteria: str = "",
    ) -> AsyncIterator[Event]:
        """1 つの escalate step を実行する。

        `context` に含めるべき最低限のフィールド:
        - `f_type`: "T1" / "T3" / "T4" のいずれか (必須)
        - `return_mode`: "assist" or "overflow" (Stage 1 は assist のみ実装)
        - f_type ごとの必須フィールド (F_TYPE_TEMPLATES を参照)

        イベントは full/atomic と同じ `Event` 型を返す (UI 側互換性)。
        エラーは EvAssistantText でユーザ向けメッセージを yield し、
        EvFinish(reason="failed") で終わる。
        """
        ctx = dict(context) if context else {}
        f_type = ctx.get("f_type")

        # 1. F type 検証
        if f_type not in SUPPORTED_F_TYPES:
            err = (
                f"escalate requires f_type in {list(SUPPORTED_F_TYPES)} "
                f"but got {f_type!r}."
            )
            logger.warning(f"[escalate] {err}")
            yield EvAssistantText(text=f"(escalate 失敗: {err})")
            yield EvFinish(reason="failed", turns=0)
            return

        # 2. return_mode: 現状は assist のみ実装 (overflow は UI 変更が必要)
        return_mode = ctx.get("return_mode", "assist")
        if return_mode != "assist":
            logger.warning(
                f"[escalate] return_mode={return_mode!r} requested but only 'assist' "
                "is implemented; treating as assist"
            )

        # 3. テンプレ構築
        try:
            user_prompt = self._build_user_prompt(
                f_type=f_type,
                task_description=task_description,
                context=ctx,
                success_criteria=success_criteria,
            )
        except ValueError as e:
            logger.warning(f"[escalate] prompt build failed: {e}")
            yield EvAssistantText(text=f"(escalate 失敗: {e})")
            yield EvFinish(reason="failed", turns=0)
            return

        system_prompt = self._get_common_system_prompt()

        # 4. Claude Sonnet 呼び出し
        logger.info(
            f"[escalate] calling {self.cfg.model} f_type={f_type} "
            f"task={task_description[:80]!r}"
        )
        try:
            resp = await self.client.messages.create(
                model=self.cfg.model,
                max_tokens=self.cfg.max_tokens,
                system=[{
                    "type": "text",
                    "text": system_prompt,
                    "cache_control": {"type": "ephemeral"},
                }],
                messages=[{"role": "user", "content": user_prompt}],
            )
        except APIError as e:
            logger.error(f"[escalate] Anthropic API error: {e}")
            yield EvAssistantText(text=f"(escalate 失敗: cloud LLM API エラー — {e})")
            yield EvFinish(reason="failed", turns=0)
            return

        _log_usage(f_type, resp.usage)

        raw_text = "".join(
            block.text for block in resp.content
            if getattr(block, "type", None) == "text"
        ).strip()
        logger.debug(f"[escalate.raw] {raw_text[:500]}")

        # 5. JSON パース → 失敗してもそのまま text を返す (Planner synthesis が拾う)
        parsed = _try_parse_json(raw_text)
        if parsed is None:
            logger.warning(
                f"[escalate] f_type={f_type} did not return valid JSON; "
                f"forwarding raw text to synthesis"
            )
            summary_text = raw_text
        else:
            # Planner synthesis に渡す自然文サマリを組む
            summary_text = self._render_summary_for_synthesis(f_type, parsed, raw_text)

        yield EvAssistantText(text=summary_text)
        yield EvFinish(reason="stop", turns=1)

    # ---- prompt construction ----
    def _build_user_prompt(
        self,
        f_type: str,
        task_description: str,
        context: dict[str, Any],
        success_criteria: str,
    ) -> str:
        """テンプレ + placeholder 差し替えで user prompt を作る。"""
        template = self._get_template(f_type)
        spec = F_TYPE_TEMPLATES[f_type]

        # 差し替えフィールドを準備。context にない値は "(未提供)" でプレースホルダ埋め。
        fields: dict[str, str] = {"task_description": task_description}
        for name in spec.required_fields:
            if name == "task_description":
                continue
            raw = context.get(name)
            if raw is None:
                logger.info(
                    f"[escalate] f_type={f_type} field {name!r} not provided by Planner; "
                    "filling with '(未提供)'"
                )
                fields[name] = "(未提供)"
            elif isinstance(raw, str):
                fields[name] = raw
            else:
                # dict / list は JSON で整形
                fields[name] = json.dumps(raw, ensure_ascii=False, indent=2)

        # success_criteria は任意で task_description に追記
        task_block = task_description.strip()
        if success_criteria:
            task_block = f"{task_block}\n\n完了条件: {success_criteria.strip()}"
        fields["task_description"] = task_block

        # str.format_map は JSON 例示中の `{...}` を format specifier と解釈して
        # 壊れるので、明示的に `{name}` → value の置換で差し替える。
        rendered = template
        for name, value in fields.items():
            rendered = rendered.replace("{" + name + "}", value)
        return rendered

    def _get_template(self, f_type: str) -> str:
        if f_type in self._templates:
            return self._templates[f_type]
        spec = F_TYPE_TEMPLATES[f_type]
        path = PROMPTS_DIR / spec.filename
        if not path.exists():
            raise ValueError(f"template file not found: {path}")
        text = path.read_text(encoding="utf-8")
        self._templates[f_type] = text
        return text

    def _get_common_system_prompt(self) -> str:
        if self._system_prompt is not None:
            return self._system_prompt
        path = PROMPTS_DIR / "common_system.md"
        if not path.exists():
            raise RuntimeError(f"common system prompt not found: {path}")
        self._system_prompt = path.read_text(encoding="utf-8")
        return self._system_prompt

    # ---- summary rendering ----
    @staticmethod
    def _render_summary_for_synthesis(
        f_type: str, parsed: dict, raw_text: str
    ) -> str:
        """parsed JSON を Planner synthesis に渡す自然文に整形。

        synthesis は「各 step の結果」を読み込んで最終回答を組む。生 JSON を
        そのまま渡してもいいが、可読性のために f_type ごとに軽く整形する。
        raw JSON も付けて事実性を落とさないように保つ。
        """
        lines = [f"[f_type={f_type}] cloud LLM による構造化出力:"]
        try:
            lines.append("```json")
            lines.append(json.dumps(parsed, ensure_ascii=False, indent=2))
            lines.append("```")
        except Exception:
            lines.append(raw_text)
        return "\n".join(lines)


# ---- helpers ----
def _try_parse_json(text: str) -> dict | None:
    """raw text から JSON object を抽出。コードフェンス内 → 地の文の順で試す。"""
    import re

    fence_re = re.compile(r"```(?:json)?\s*\n(.*?)\n```", re.DOTALL)
    m = fence_re.search(text)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass

    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        try:
            return json.loads(text[start : end + 1])
        except json.JSONDecodeError:
            pass

    return None


def _log_usage(f_type: str, usage: Any) -> None:
    if usage is None:
        return
    inp = getattr(usage, "input_tokens", 0) or 0
    cw = getattr(usage, "cache_creation_input_tokens", 0) or 0
    cr = getattr(usage, "cache_read_input_tokens", 0) or 0
    out = getattr(usage, "output_tokens", 0) or 0
    total_in = inp + cw + cr
    hit = (cr / total_in * 100.0) if total_in > 0 else 0.0
    logger.info(
        f"[escalate.usage] f_type={f_type} in={inp} cache_write={cw} "
        f"cache_read={cr} out={out} (hit={hit:.0f}%)"
    )
