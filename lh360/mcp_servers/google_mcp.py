"""Google Workspace FastMCP Server — Calendar / Gmail。

ツール一覧:
  [Calendar]
    calendar_list_events, calendar_check_availability, calendar_create_event
  [Gmail]
    gmail_create_draft
"""
from __future__ import annotations

import base64
import logging
import os
from datetime import datetime, timedelta, timezone
from email.mime.text import MIMEText
from pathlib import Path
from typing import Any

from googleapiclient.discovery import build
from mcp.server.fastmcp import FastMCP

from mcp_clients.google_auth import get_credentials

logger = logging.getLogger("google_mcp")

# ---- Paths / Config ----
ROOT = Path(__file__).resolve().parents[1]
CRED_PATH = Path(os.environ.get("GOOGLE_OAUTH_CREDENTIALS", ROOT / "config" / "tokens" / "google_credentials.json"))
TOKEN_PATH = Path(os.environ.get("GOOGLE_OAUTH_TOKEN", ROOT / "config" / "tokens" / "google_token.json"))

JST = timezone(timedelta(hours=9))

# ---- Lazy singletons (起動を軽くする + 環境未整備でも一部ツールは動くように) ----
_creds = None
_calendar_svc = None
_gmail_svc = None


def _get_creds():
    global _creds
    if _creds is None:
        _creds = get_credentials(CRED_PATH, TOKEN_PATH)
    return _creds


def _calendar():
    global _calendar_svc
    if _calendar_svc is None:
        _calendar_svc = build("calendar", "v3", credentials=_get_creds(), cache_discovery=False)
    return _calendar_svc


def _gmail():
    global _gmail_svc
    if _gmail_svc is None:
        _gmail_svc = build("gmail", "v1", credentials=_get_creds(), cache_discovery=False)
    return _gmail_svc


# ---- FastMCP ----
mcp = FastMCP(
    name="google-workspace",
    instructions=(
        "Google Calendar / Gmail へのアクセス。"
        "Calendar は予定参照・空き確認・仮押さえ。Gmail は下書き作成のみ(送信はしない)。"
    ),
)


# ============== Calendar ==============
@mcp.tool()
def calendar_list_events(
    start_iso: str,
    end_iso: str,
    calendar_id: str = "primary",
    max_results: int = 50,
) -> dict:
    """指定時間範囲の予定を一覧取得。
    Args:
        start_iso/end_iso: RFC3339 (例 '2026-05-12T00:00:00+09:00')
    """
    svc = _calendar()
    items = (
        svc.events()
        .list(
            calendarId=calendar_id,
            timeMin=start_iso,
            timeMax=end_iso,
            singleEvents=True,
            orderBy="startTime",
            maxResults=max_results,
        )
        .execute()
        .get("items", [])
    )
    return {
        "events": [
            {
                "id": e.get("id"),
                "summary": e.get("summary"),
                "start": e.get("start", {}).get("dateTime") or e.get("start", {}).get("date"),
                "end": e.get("end", {}).get("dateTime") or e.get("end", {}).get("date"),
                "status": e.get("status"),
                "location": e.get("location"),
                "description": e.get("description"),
            }
            for e in items
        ],
        "count": len(items),
    }


@mcp.tool()
def calendar_check_availability(
    candidate_slots: list[dict],
    calendar_id: str = "primary",
) -> dict:
    """候補スロットリストの空き/busy を判定。
    Args:
        candidate_slots: [{'start': ISO, 'end': ISO}, ...]
    Returns:
        {slots: [{start, end, busy, conflicts: [{summary, start, end}]}]}
    """
    if not candidate_slots:
        return {"slots": []}
    svc = _calendar()
    # freebusy は分単位で時間範囲を指定
    start_min = min(s["start"] for s in candidate_slots)
    end_max = max(s["end"] for s in candidate_slots)
    fb = svc.freebusy().query(body={
        "timeMin": start_min,
        "timeMax": end_max,
        "items": [{"id": calendar_id}],
    }).execute()
    busy = fb.get("calendars", {}).get(calendar_id, {}).get("busy", [])
    busy_ranges = [(datetime.fromisoformat(b["start"].replace("Z", "+00:00")),
                    datetime.fromisoformat(b["end"].replace("Z", "+00:00")),
                    b) for b in busy]

    # 詳細な conflict 取得のため対象範囲の events も取得
    evs = svc.events().list(
        calendarId=calendar_id, timeMin=start_min, timeMax=end_max,
        singleEvents=True, orderBy="startTime",
    ).execute().get("items", [])

    results = []
    for s in candidate_slots:
        ss = datetime.fromisoformat(s["start"].replace("Z", "+00:00"))
        se = datetime.fromisoformat(s["end"].replace("Z", "+00:00"))
        is_busy = False
        conflicts = []
        for bs, be, _ in busy_ranges:
            if ss < be and bs < se:
                is_busy = True
        for e in evs:
            es_str = e.get("start", {}).get("dateTime")
            ee_str = e.get("end", {}).get("dateTime")
            if not es_str or not ee_str:
                continue
            es = datetime.fromisoformat(es_str.replace("Z", "+00:00"))
            ee = datetime.fromisoformat(ee_str.replace("Z", "+00:00"))
            if ss < ee and es < se:
                conflicts.append({
                    "summary": e.get("summary"),
                    "start": es_str,
                    "end": ee_str,
                })
        results.append({
            "start": s["start"],
            "end": s["end"],
            "busy": is_busy,
            "conflicts": conflicts,
        })
    return {"slots": results}


@mcp.tool()
def calendar_create_event(
    summary: str,
    start_iso: str,
    end_iso: str,
    description: str | None = None,
    location: str | None = None,
    attendees: list[str] | None = None,
    calendar_id: str = "primary",
    tentative: bool = False,
    color_id: str | int | None = None,
) -> dict:
    """カレンダーに予定を作成。tentative=True で仮押さえ状態で登録。
    Args:
        attendees: email のリスト (招待を送らず添えるのみなら sendUpdates=none)
        color_id: 1-11 (Google Calendar の色 ID)。数値でも文字列でも可。
    """
    svc = _calendar()
    body: dict[str, Any] = {
        "summary": summary,
        "start": {"dateTime": start_iso, "timeZone": "Asia/Tokyo"},
        "end": {"dateTime": end_iso, "timeZone": "Asia/Tokyo"},
    }
    if description:
        body["description"] = description
    if location:
        body["location"] = location
    if attendees:
        body["attendees"] = [{"email": a} for a in attendees]
    if tentative:
        body["status"] = "tentative"
    if color_id is not None and str(color_id).strip():
        body["colorId"] = str(color_id)  # Google API は string 必須

    ev = svc.events().insert(
        calendarId=calendar_id, body=body, sendUpdates="none"
    ).execute()
    return {
        "id": ev.get("id"),
        "htmlLink": ev.get("htmlLink"),
        "status": ev.get("status"),
        "start": ev.get("start", {}).get("dateTime"),
        "end": ev.get("end", {}).get("dateTime"),
    }


# ============== Gmail ==============
@mcp.tool()
def gmail_create_draft(
    to: str,
    subject: str,
    body: str,
    cc: str | None = None,
    bcc: str | None = None,
) -> dict:
    """Gmail 下書きを作成（送信はしない）。"""
    msg = MIMEText(body, "plain", "utf-8")
    msg["to"] = to
    msg["subject"] = subject
    if cc:
        msg["cc"] = cc
    if bcc:
        msg["bcc"] = bcc
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    svc = _gmail()
    draft = svc.users().drafts().create(userId="me", body={"message": {"raw": raw}}).execute()
    return {
        "id": draft.get("id"),
        "messageId": draft.get("message", {}).get("id"),
    }


# ============== Entry ==============
def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
    mcp.run()


if __name__ == "__main__":
    main()
