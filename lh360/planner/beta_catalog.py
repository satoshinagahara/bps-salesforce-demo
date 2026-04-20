"""β elementary カタログのロードと Planner 向け整形。

Phase α-3 での用途:
- Planner system prompt に埋め込む「ユースケース地図」として使う
- Planner が ID (例 "e7-5-b") で elementary を参照できるようにする

【構造】
- groups: P1-P7 の業務グループ (title + workload_type)
- elementaries: 284 件。id / group / task / A-F pattern 等

【コンパクト表現】
YAML full (47KB) を Planner に渡すと context を食いすぎる。
Planner 向けには tab-separated の 1 行表現に詰める:
  `e1-1-a  P1  D  task...`
これで ~20k tokens 以内に収まる想定。

初期は全量を system prompt に埋め込む (方式 A)。
コスト顕在化時に workload_type 単位で絞る方式 C に切替予定。
"""
from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml


DEFAULT_CATALOG_PATH = Path(__file__).resolve().parents[1] / "data" / "beta_catalog.yaml"


@dataclass(frozen=True)
class Elementary:
    id: str
    group: str           # P1-P7
    task: str
    src: str
    op: str
    out: str
    hop: str
    trig: str
    absn: str
    pattern: str         # A-F


@dataclass(frozen=True)
class Group:
    id: str              # P1..P7
    title: str
    workload_type: str   # 思考補助型 / 操作代行型 / ドラフト量産型 / モニタリング型


class BetaCatalog:
    """β catalog のロード・検索・LLM 向け整形。"""

    def __init__(self, groups: list[Group], elementaries: list[Elementary]):
        self.groups = groups
        self.elementaries = elementaries
        self._by_id = {e.id: e for e in elementaries}
        self._by_group: dict[str, list[Elementary]] = {}
        for e in elementaries:
            self._by_group.setdefault(e.group, []).append(e)

    def get(self, elementary_id: str) -> Elementary | None:
        return self._by_id.get(elementary_id)

    def for_group(self, group_id: str) -> list[Elementary]:
        return self._by_group.get(group_id, [])

    def compact_lines(self, include_f: bool = True) -> str:
        """Planner system prompt 埋め込み用のコンパクト表現。

        列: id  group  pattern  hop  absn  task
        F を除外したい場合 include_f=False (γ escalation 実装前の暫定)。
        """
        lines = []
        for e in self.elementaries:
            if not include_f and e.pattern == "F":
                continue
            # tab 区切りで token を節約
            lines.append(f"{e.id}\t{e.group}\t{e.pattern}\t{e.hop}\t{e.absn}\t{e.task}")
        return "\n".join(lines)

    def groups_summary(self) -> str:
        """グループ一覧の整形。"""
        return "\n".join(
            f"- {g.id} {g.title} ({g.workload_type})" for g in self.groups
        )


@lru_cache(maxsize=1)
def load_catalog(path: str | None = None) -> BetaCatalog:
    """デフォルトパス (data/beta_catalog.yaml) から catalog を読む。

    lru_cache でプロセスごとに 1 回のみ parse。
    """
    p = Path(path) if path else DEFAULT_CATALOG_PATH
    if not p.exists():
        raise FileNotFoundError(
            f"beta_catalog.yaml not found at {p}. "
            "Run `uv run python scripts/build_beta_catalog.py` to generate it."
        )
    raw = yaml.safe_load(p.read_text(encoding="utf-8")) or {}

    groups = [Group(**g) for g in raw.get("groups", [])]
    elementaries = [Elementary(**e) for e in raw.get("elementaries", [])]
    return BetaCatalog(groups, elementaries)
