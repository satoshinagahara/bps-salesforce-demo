"""Planner 出力を CLI から一括検証する。

目的:
- Sonnet Planner のプラン生成挙動を Gemma/MCP 実行なしで観察
- elementary_id の選択妥当性、atomic vs full の判断、available_tools の指定内容を確認
- α-4 チューニングで調整すべきプロンプト部位を洗い出す

実行:
  cd lh360
  uv run python scripts/planner_batch.py
  # or 特定ケースだけ:
  uv run python scripts/planner_batch.py --only 2,5
  # or カスタム prompt:
  uv run python scripts/planner_batch.py --prompt "今日のアポイント一覧見せて"

結果は標準出力 + tmp/planner_batch/<timestamp>/ に JSON/log 保存。
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from dotenv import load_dotenv

load_dotenv(ROOT / ".env")

from agent.mcp_manager import MCPManager  # noqa: E402
from app.gradio_app import _current_specs  # noqa: E402
from planner import PlannerLLM, load_catalog  # noqa: E402
from planner.orchestrator import Orchestrator, _plan_from_json  # noqa: E402


logger = logging.getLogger("planner_batch")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)


# ---- 検証ケース ----
TEST_CASES: list[dict] = [
    # (id, prompt, expected_hint) — expected_hint は assertion でなく人間レビュー用ヒント
    {"id": 1, "prompt": "こんにちは", "hint": "trivial / 1-step full / elementary_id=null"},
    {"id": 2, "prompt": "今週のパイプライン状況を集計して", "hint": "A pattern / atomic / e7-5-a 近辺"},
    {"id": 3, "prompt": "今担当している取引先を一覧で見せて", "hint": "A pattern / atomic"},
    {"id": 4, "prompt": "今日のアポイント一覧と関連する商談を教えて", "hint": "B pattern / atomic or 2-step"},
    {"id": 5, "prompt": "今四半期の優先商談トップ3とそれぞれの担当者の連絡先を教えて", "hint": "複数step連結 (例 3 と同じ形)"},
    {"id": 6, "prompt": "なんか最近ご無沙汰な顧客いない？", "hint": "曖昧 → elementary_id=null or 文脈解決要"},
    {"id": 7, "prompt": "直近の商談にフォローアップメールを下書きしておいて", "hint": "C pattern / draft 系 / どの商談か文脈不足"},
    {"id": 8, "prompt": "この顧客の戦略的価値を評価してほしい", "hint": "F pattern / α-5 未稼働なので full にフォールバック想定"},
    {"id": 9, "prompt": "今月の活動サマリをレポートにして", "hint": "A or C / レポート形式"},
    {"id": 10, "prompt": "来週の火曜日 14 時から 1 時間、中村部長と打ち合わせをセットしたい", "hint": "C pattern / calendar 書き込み"},
]


async def main(args):
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("❌ ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    only = set(int(x) for x in args.only.split(",")) if args.only else None
    custom = args.prompt
    cases = (
        [{"id": 0, "prompt": custom, "hint": "(custom)"}]
        if custom
        else [c for c in TEST_CASES if (only is None or c["id"] in only)]
    )
    if not cases:
        print("no cases to run")
        return

    # 出力先
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = ROOT / "tmp" / "planner_batch" / ts
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"📁 output: {out_dir}")

    # MCP 起動 (Planner prompt の AVAILABLE_TOOLS 用に tool 一覧が要る)
    specs = _current_specs()
    print(f"🔌 starting MCP: {[s.name for s in specs]}")
    async with MCPManager(specs) as mgr:
        tool_names = [t.qualified_name for t in mgr.tools]
        print(f"   {len(mgr.tools)} tools available")
        (out_dir / "tools.txt").write_text("\n".join(sorted(tool_names)), encoding="utf-8")

        # Planner 準備 (Orchestrator を使い回し、render だけ再利用する)
        llm = PlannerLLM()
        catalog = load_catalog()
        print(f"📚 catalog: {len(catalog.elementaries)} elementaries, {len(catalog.groups)} groups")

        # MCP tools を見られる最小 full_executor スタブ
        class _ExecStub:
            mcp = mgr
        orch = Orchestrator(
            full_executor=_ExecStub(),
            planner_llm=llm,
            catalog=catalog,
            atomic_executor=object(),  # allow_atomic=True にするためのダミー
        )
        system_prompt = orch._get_planner_system_prompt()
        print(f"📝 system prompt rendered: {len(system_prompt)} chars")
        (out_dir / "system_prompt.md").write_text(system_prompt, encoding="utf-8")

        valid_elem_ids = {e.id for e in catalog.elementaries}

        summary: list[dict] = []
        for case in cases:
            print(f"\n=== case {case['id']}: {case['prompt']!r} ===")
            print(f"  hint: {case['hint']}")
            user_prompt = (
                f"## 現ターンのユーザ発話\n{case['prompt']}\n\n"
                "## 指示\n上記のユーザ発話に対応する plan を JSON object で出力せよ。JSON 以外は出力しない。"
            )
            try:
                raw = await llm.generate_plan_json(system_prompt, user_prompt)
            except Exception as e:
                print(f"  ❌ planner failed: {type(e).__name__}: {e}")
                summary.append({"id": case["id"], "prompt": case["prompt"], "error": str(e)})
                continue

            plan = _plan_from_json(raw, allow_atomic=True)
            # 観察項目
            print(f"  user_intent: {plan.user_intent}")
            print(f"  classification: {raw.get('classification')}")
            print(f"  steps: {len(plan.steps)}")
            warnings: list[str] = []
            for s in plan.steps:
                elem_ok = (s.elementary_id is None) or (s.elementary_id in valid_elem_ids)
                elem_note = "" if elem_ok else " ⚠UNKNOWN elementary_id"
                tool_count = len(s.available_tools) if s.available_tools else 0
                tool_note = ""
                if s.mode == "atomic":
                    if not s.available_tools:
                        tool_note = " ⚠atomic but no available_tools"
                    else:
                        unknown = [t for t in s.available_tools if t not in tool_names]
                        if unknown:
                            tool_note = f" ⚠unknown tools: {unknown}"
                print(
                    f"    {s.step_id} mode={s.mode} elem={s.elementary_id}{elem_note} "
                    f"tools={tool_count}{tool_note}"
                )
                print(f"      desc: {s.task_description[:100]}")
                if not elem_ok:
                    warnings.append(f"{s.step_id}: unknown elementary_id={s.elementary_id}")
                if tool_note:
                    warnings.append(f"{s.step_id}: {tool_note.strip('⚠ ')}")
            if plan.synthesis_hint:
                print(f"  synthesis_hint: {plan.synthesis_hint}")

            # 保存
            case_out = {
                "id": case["id"],
                "prompt": case["prompt"],
                "hint": case["hint"],
                "raw_plan": raw,
                "warnings": warnings,
            }
            (out_dir / f"case_{case['id']:02d}.json").write_text(
                json.dumps(case_out, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            summary.append({
                "id": case["id"],
                "prompt": case["prompt"],
                "classification": raw.get("classification"),
                "n_steps": len(plan.steps),
                "modes": [s.mode for s in plan.steps],
                "elementary_ids": [s.elementary_id for s in plan.steps],
                "warnings": warnings,
            })

        # 一覧レポート
        (out_dir / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"\n📊 summary:")
        for s in summary:
            w = f" ⚠{len(s.get('warnings') or [])}" if s.get("warnings") else ""
            print(
                f"  [{s['id']:>2}] cls={s.get('classification','?'):>7} "
                f"steps={s.get('n_steps','?')} modes={s.get('modes','?')}{w}  "
                f"{s['prompt']}"
            )
        print(f"\n📁 saved to: {out_dir}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="comma-separated case ids to run (e.g. '2,5')")
    parser.add_argument("--prompt", help="run a single custom prompt instead of TEST_CASES")
    args = parser.parse_args()
    asyncio.run(main(args))
