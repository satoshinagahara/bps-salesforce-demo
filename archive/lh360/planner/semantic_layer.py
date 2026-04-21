"""Salesforce セマンティックレイヤーのロードと Planner 向け整形。

目的:
- Planner は 1 回の JSON 生成で plan を出す構造のため、`sf__describe-object` を
  on-demand で呼べない。Planner が plan を組む時点で「このカスタムオブジェクトは
  何か」「どのように業務に使われるか」を知っている必要がある
- describe API では取れない **業務意味** (例: Meeting_Record__c は提案への反応が
  記録される最重要ソース) を人が curate した YAML から取り込む

【スコープ (MVP)】
- Planner のみに渡す (AtomicExecutor には当面渡さない)
- SAE が触る主要オブジェクトに限定 (5-10 件)
- 最小情報 (業務意味 + 主要フィールド + 使い方 hint)

設計: docs/design/lh360-f-pattern-cloud-offload-design.md + semantic layer 議論
"""
from __future__ import annotations

from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml


DEFAULT_SEMANTIC_LAYER_PATH = (
    Path(__file__).resolve().parents[1] / "data" / "sf_semantic_layer.yaml"
)
DEFAULT_WORKSPACE_SEMANTIC_LAYER_PATH = (
    Path(__file__).resolve().parents[1] / "data" / "gw_semantic_layer.yaml"
)


@dataclass(frozen=True)
class SemanticLayer:
    """SF オブジェクトの業務意味辞書。

    Planner system prompt 埋め込み用のレンダラを提供する。YAML 全文をそのまま
    流し込む方式を採る (構造化を強制すると Planner が読みにくく、trim したら
    情報欠落するため、人が書いたテキストをそのまま渡すのが最も素直)。
    """

    version: str
    scope: str
    raw_text: str
    """YAML 全文 (コメント・空行含む)。Planner にはこれをそのまま渡す。"""

    object_count: int
    """含まれるオブジェクト数 (ログ用)。"""

    def as_prompt_block(self) -> str:
        """Planner system prompt の `{SF_SEMANTIC_LAYER}` に差し込むテキスト。

        YAML ブロックとして囲って渡す。Planner に「これは参考情報であり必ず使え
        とは言わない」という温度感を維持する (強制すると過剰適合する)。
        """
        lines = [
            f"> この org のセマンティック情報 (version={self.version})。",
            "> Planner が plan を組む際の参考。全カスタムオブジェクトが列挙されて",
            "> いるわけではないので、ここにない API 名でも存在する可能性はある。",
            "",
            "```yaml",
            self.raw_text.rstrip(),
            "```",
        ]
        return "\n".join(lines)


@lru_cache(maxsize=1)
def load_semantic_layer(path: str | None = None) -> SemanticLayer:
    """デフォルトパス (data/sf_semantic_layer.yaml) からセマンティックレイヤーを読む。

    lru_cache でプロセスごとに 1 回のみ parse。YAML として validate はするが、
    Planner には raw_text をそのまま渡す (構造化したあと再シリアライズすると
    コメントが落ちて意味が薄まるため)。
    """
    p = Path(path) if path else DEFAULT_SEMANTIC_LAYER_PATH
    if not p.exists():
        raise FileNotFoundError(
            f"sf_semantic_layer.yaml not found at {p}. "
            "Semantic layer is manually curated; create the file if it's missing."
        )
    raw_text = p.read_text(encoding="utf-8")
    parsed: dict[str, Any] = yaml.safe_load(raw_text) or {}

    version = str(parsed.get("version") or "unknown")
    scope = str(parsed.get("scope") or "")
    objects = parsed.get("objects") or []
    if not isinstance(objects, list):
        raise ValueError("sf_semantic_layer.yaml: 'objects' must be a list")

    return SemanticLayer(
        version=version,
        scope=scope,
        raw_text=raw_text,
        object_count=len(objects),
    )


@dataclass(frozen=True)
class WorkspaceSemanticLayer:
    """Gmail / Gcal / Web fetch / Time MCP 群の業務的使い分けヒント辞書。

    SF の SemanticLayer と並列の Planner 専用リソース。Phase A (2026-04-20) で
    新設。YAML 全文をそのまま Planner system prompt に注入する方針は SF 同様。
    """

    version: str
    scope: str
    raw_text: str
    tool_count: int
    """含まれる tool ヒント数 (ログ用、ざっくり)。"""

    def as_prompt_block(self) -> str:
        """Planner system prompt の `{GW_SEMANTIC_LAYER}` に差し込むテキスト。"""
        lines = [
            f"> Workspace / Web MCP 群の業務ヒント (version={self.version})。",
            "> Gmail / Gcal / fetch / time の使い分けを記載。全 tool が網羅されて",
            "> いるわけではないので、ここにない tool も AVAILABLE_TOOLS にあれば使える。",
            "",
            "```yaml",
            self.raw_text.rstrip(),
            "```",
        ]
        return "\n".join(lines)


@lru_cache(maxsize=1)
def load_workspace_semantic_layer(path: str | None = None) -> WorkspaceSemanticLayer:
    """デフォルトパス (data/gw_semantic_layer.yaml) から workspace 層を読む。"""
    p = Path(path) if path else DEFAULT_WORKSPACE_SEMANTIC_LAYER_PATH
    if not p.exists():
        raise FileNotFoundError(
            f"gw_semantic_layer.yaml not found at {p}. "
            "Workspace semantic layer is manually curated; create the file if missing."
        )
    raw_text = p.read_text(encoding="utf-8")
    parsed: dict[str, Any] = yaml.safe_load(raw_text) or {}

    version = str(parsed.get("version") or "unknown")
    scope = str(parsed.get("scope") or "")

    # tool_count はざっくり: 各 section の tools / calendar_tools の長さを合算
    tool_count = 0
    for section in ("google_workspace", "fetch", "time"):
        sect = parsed.get(section) or {}
        if not isinstance(sect, dict):
            continue
        for key in ("tools", "calendar_tools"):
            items = sect.get(key) or []
            if isinstance(items, list):
                tool_count += len(items)

    return WorkspaceSemanticLayer(
        version=version,
        scope=scope,
        raw_text=raw_text,
        tool_count=tool_count,
    )
