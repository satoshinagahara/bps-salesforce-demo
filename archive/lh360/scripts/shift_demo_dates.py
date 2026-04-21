"""lh360 デモデータ日付一括シフトスクリプト。

Is_Demo_Seed__c = true の全レコードの日付フィールドを指定日数だけ
一律シフトする。デモ実行日からしばらく時間が経った場合に、日付の
鮮度を取り戻すのに使う。

【シフト対象フィールド】（user-controllable のみ）
- Opportunity.CloseDate
- Task.ActivityDate
- Event.ActivityDate
- Event.ActivityDateTime
- Event.StartDateTime (Event.ActivityDateTime 派生のため通常不要)
- Event.EndDateTime   (同上)

【シフトしない】
- CreatedDate / LastModifiedDate (system-managed, API更新不可)
  → UI 表示で問題にならない前提

【使い方】
  # 2 週間先に動かす
  python lh360/scripts/shift_demo_dates.py --days 14
  # 何を動かすか事前確認
  python lh360/scripts/shift_demo_dates.py --days 14 --dry-run
"""
from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
import tempfile
from datetime import date, datetime, timedelta
from pathlib import Path

ORG = "trailsignup.61aa736aacb04f@salesforce.com"


def sh(cmd: list[str], check: bool = True) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"[sh failed] {' '.join(cmd)}", file=sys.stderr)
        print(r.stdout, file=sys.stderr)
        print(r.stderr, file=sys.stderr)
        raise RuntimeError(f"command failed: {cmd[0]}")
    return r.stdout


def soql(query: str) -> list[dict]:
    out = sh(["sf", "data", "query", "--query", query, "--target-org", ORG,
              "--result-format", "json"])
    return json.loads(out).get("result", {}).get("records", [])


def bulk_update(sobject: str, rows: list[dict]) -> None:
    if not rows:
        return
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
        csv_path = f.name
    try:
        r = subprocess.run(
            ["sf", "data", "update", "bulk", "--sobject", sobject,
             "--file", csv_path, "--wait", "10",
             "--line-ending", "CRLF",
             "--target-org", ORG],
            capture_output=True, text=True,
        )
        tail = "\n".join(r.stdout.splitlines()[-15:])
        print(tail)
        if r.returncode != 0:
            print(f"  [bulk error] exit={r.returncode}")
            print(r.stderr[:500])
            print(f"  [csv retained for debug] {csv_path}")
            return
    finally:
        if 'r' in locals() and r.returncode == 0:
            Path(csv_path).unlink(missing_ok=True)


def shift_date_str(s: str, days: int) -> str:
    # "2026-04-19" → +days
    d = date.fromisoformat(s)
    return (d + timedelta(days=days)).isoformat()


def shift_datetime_str(s: str, days: int) -> str:
    """SF datetime 文字列を days 日シフト。

    SF の API は "2026-04-19T01:00:00.000+0000" 形式で返す。
    Python 3.9 の fromisoformat は "+00:00" は受け付けるが "+0000" は不可。
    strptime を使って %z で両形式を受ける。
    """
    # "2026-04-19T01:00:00.000+0000" → strptime %Y-%m-%dT%H:%M:%S.%f%z
    try:
        dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f%z")
    except ValueError:
        # Z 末尾
        if s.endswith("Z"):
            dt = datetime.strptime(s.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z")
        else:
            raise
    shifted = dt + timedelta(days=days)
    # 返却は +0000 形式（SFは両方受けるがUTCで返ってきたものはUTCで返す）
    return shifted.strftime("%Y-%m-%dT%H:%M:%S.000%z")


def shift_opportunities(days: int, dry_run: bool) -> int:
    recs = soql(
        "SELECT Id, Name, CloseDate FROM Opportunity WHERE Is_Demo_Seed__c = true"
    )
    print(f"\n[Opportunity] {len(recs)} records")
    rows = []
    for r in recs:
        if not r.get("CloseDate"):
            continue
        new_date = shift_date_str(r["CloseDate"], days)
        print(f"  {r['Name'][:40]}: {r['CloseDate']} → {new_date}")
        rows.append({"Id": r["Id"], "CloseDate": new_date})
    if not dry_run:
        bulk_update("Opportunity", rows)
    return len(rows)


def shift_tasks(days: int, dry_run: bool) -> int:
    recs = soql(
        "SELECT Id, Subject, ActivityDate FROM Task WHERE Is_Demo_Seed__c = true"
    )
    print(f"\n[Task] {len(recs)} records")
    rows = []
    for r in recs:
        if not r.get("ActivityDate"):
            continue
        new_date = shift_date_str(r["ActivityDate"], days)
        rows.append({"Id": r["Id"], "ActivityDate": new_date})
    print(f"  shifting {len(rows)} Tasks by {days} days")
    if not dry_run:
        bulk_update("Task", rows)
    return len(rows)


def shift_events(days: int, dry_run: bool) -> int:
    recs = soql(
        "SELECT Id, Subject, ActivityDate, ActivityDateTime FROM Event WHERE Is_Demo_Seed__c = true"
    )
    print(f"\n[Event] {len(recs)} records")
    rows = []
    for r in recs:
        row = {"Id": r["Id"]}
        if r.get("ActivityDate"):
            row["ActivityDate"] = shift_date_str(r["ActivityDate"], days)
        if r.get("ActivityDateTime"):
            row["ActivityDateTime"] = shift_datetime_str(r["ActivityDateTime"], days)
        if len(row) > 1:
            rows.append(row)
    print(f"  shifting {len(rows)} Events by {days} days")
    if not dry_run:
        bulk_update("Event", rows)
    return len(rows)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, required=True,
                    help="全日付を N 日後ろにシフト（負の値で過去シフト）")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    print(f"=== shift_demo_dates (days={args.days}, dry_run={args.dry_run}) ===")

    n_opp = shift_opportunities(args.days, args.dry_run)
    n_task = shift_tasks(args.days, args.dry_run)
    n_event = shift_events(args.days, args.dry_run)

    print(f"\n=== summary: Opp {n_opp} / Task {n_task} / Event {n_event} shifted ===")


if __name__ == "__main__":
    main()
