"""β catalog 抽出: usecase-pattern-analysis.md → beta_catalog.yaml

docs/in-progress/lh360-usecase-pattern-analysis.md の Step 3b テーブルから
elementary 行を抽出し Planner が参照しやすい YAML を生成する。

【出力フォーマット】
groups:
  - id: P1
    title: アカウント戦略立案
    workload_type: 思考補助型   # Step 4 の 4 類型
  ...
elementaries:
  - id: e1-1-a
    group: P1
    task: 顧客 IR/開示情報の公式 URL 特定・SFDC 保存
    src: e
    op: corr
    out: W-s
    hop: "2"
    trig: i
    absn: lo
    pattern: D

【使い方】
  uv run python scripts/build_beta_catalog.py

β 分析 md が更新された場合のみ再生成する (デモ中は頻繁には回らない想定)。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
BETA_MD = REPO_ROOT / "docs" / "in-progress" / "lh360-usecase-pattern-analysis.md"
OUT_YAML = Path(__file__).resolve().parents[1] / "data" / "beta_catalog.yaml"

# Step 4 の 4 類型マッピング (md §Step 4 から)
WORKLOAD_TYPES = {
    "P1": ("アカウント戦略立案", "思考補助型"),
    "P2": ("商談創出・育成", "ドラフト量産型"),
    "P3": ("提案策定", "ドラフト量産型"),
    "P4": ("商談クロージング", "ドラフト量産型"),
    "P5": ("デリバリー伴走", "モニタリング型"),
    "P6": ("アカウント成長・LTV 最大化", "ドラフト量産型"),
    "P7": ("社内コミュニケーション・SFA 運用", "操作代行型"),
}

# markdown テーブル行: "| e1-1-a | 顧客 IR... | e | corr | W-s | 2 | i | lo | **D** |"
# 空白許容、pattern 列は `**X**` または `(out) X` または `X` を受ける
ROW_RE = re.compile(
    r"^\|\s*(e\d+-\d+-\w+)"        # id
    r"\s*\|\s*(.*?)"                # task
    r"\s*\|\s*([^\|]*?)"            # src
    r"\s*\|\s*([^\|]*?)"            # op
    r"\s*\|\s*([^\|]*?)"            # out
    r"\s*\|\s*([^\|]*?)"            # hop
    r"\s*\|\s*([^\|]*?)"            # trig
    r"\s*\|\s*([^\|]*?)"            # absn
    r"\s*\|\s*([^\|]*?)"            # pattern
    r"\s*\|\s*$"
)


def clean_pattern(raw: str) -> str | None:
    """`**D**` や `(out) C` を D / (out) C に。空/ダッシュは None。"""
    s = raw.strip().replace("**", "").strip()
    if not s or s == "—" or s == "-":
        return None
    return s


def clean_cell(raw: str) -> str:
    return raw.strip().replace("**", "").strip()


def extract() -> dict:
    if not BETA_MD.exists():
        raise FileNotFoundError(BETA_MD)
    text = BETA_MD.read_text(encoding="utf-8")

    elementaries: list[dict] = []
    seen_ids: set[str] = set()

    for line in text.splitlines():
        m = ROW_RE.match(line)
        if not m:
            continue
        eid = m.group(1).strip()
        # 判定表の説明行 (例: "e1-1-a" ではなく "** 構造") はヒットしないはず。念のため dedupe
        if eid in seen_ids:
            # 同一 ID 重複は data 異常。最初だけ採用
            continue
        seen_ids.add(eid)

        group_num = eid.split("-")[0][1:]  # "e1-1-a" → "1"
        group = f"P{group_num}"

        pattern = clean_pattern(m.group(9))
        # scope:out や未分類 (物理行動) はスキップ
        if pattern is None:
            continue
        # `scope: out` や `(out) C` 等の仮分類は lh360 target 外として除外
        # (β 分析 §Step 3b-pre: A-E が lh360 正規 target、out は将来の参考)
        if pattern.startswith("(out)") or pattern.startswith("`scope"):
            continue

        elementaries.append({
            "id": eid,
            "group": group,
            "task": clean_cell(m.group(2)),
            "src": clean_cell(m.group(3)),
            "op": clean_cell(m.group(4)),
            "out": clean_cell(m.group(5)),
            "hop": clean_cell(m.group(6)),
            "trig": clean_cell(m.group(7)),
            "absn": clean_cell(m.group(8)),
            "pattern": pattern,
        })

    # group meta
    groups = []
    for gid in sorted(WORKLOAD_TYPES.keys()):
        title, workload = WORKLOAD_TYPES[gid]
        groups.append({"id": gid, "title": title, "workload_type": workload})

    return {
        "source": "docs/in-progress/lh360-usecase-pattern-analysis.md",
        "note": (
            "A-E = lh360 local Gemma target (88%). F = cloud LLM offload (12%, γ 設計参照)。"
            " scope:out の elementary は除外済み。"
        ),
        "groups": groups,
        "elementaries": elementaries,
    }


def summarize(catalog: dict) -> None:
    es = catalog["elementaries"]
    print(f"total: {len(es)}")
    from collections import Counter
    by_group = Counter(e["group"] for e in es)
    by_pat = Counter(e["pattern"] for e in es)
    print("by group:", dict(sorted(by_group.items())))
    print("by pattern:", dict(sorted(by_pat.items())))


def main() -> None:
    catalog = extract()
    summarize(catalog)
    OUT_YAML.parent.mkdir(parents=True, exist_ok=True)
    OUT_YAML.write_text(
        yaml.safe_dump(catalog, allow_unicode=True, sort_keys=False, width=200),
        encoding="utf-8",
    )
    print(f"wrote: {OUT_YAML}")


if __name__ == "__main__":
    main()
