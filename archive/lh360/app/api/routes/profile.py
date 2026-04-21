"""GET /profile / PUT /profile — ユーザープロファイル IO。"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from ..mcp_config import ROOT

PROFILE_PATH = Path(os.environ.get("USER_PROFILE_PATH", ROOT / "config" / "user_profile.yaml"))

router = APIRouter()


class WorkPattern(BaseModel):
    monday: str = "office"
    tuesday: str = "office"
    wednesday: str = "office"
    thursday: str = "flexible"
    friday: str = "home"
    saturday: str = "home"
    sunday: str = "home"


class WorkingHours(BaseModel):
    start: str = "09:00"
    end: str = "18:00"


class VisitBuffer(BaseModel):
    before: int = 15
    after: int = 10


class LocationEntry(BaseModel):
    label: str = ""
    address: str = ""


class Locations(BaseModel):
    office: LocationEntry = LocationEntry()
    home: LocationEntry = LocationEntry()


class UserInfo(BaseModel):
    name: str = ""
    email: str = ""
    role: str = ""


class ProfileData(BaseModel):
    user: UserInfo = UserInfo()
    locations: Locations = Locations()
    work_pattern: WorkPattern = WorkPattern()
    working_hours: WorkingHours = WorkingHours()
    visit_buffer: VisitBuffer = VisitBuffer()


@router.get("/profile")
async def get_profile() -> dict[str, Any]:
    if not PROFILE_PATH.exists():
        return {}
    try:
        return yaml.safe_load(PROFILE_PATH.read_text(encoding="utf-8")) or {}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/profile")
async def put_profile(data: ProfileData) -> dict[str, str]:
    try:
        PROFILE_PATH.parent.mkdir(parents=True, exist_ok=True)
        PROFILE_PATH.write_text(
            yaml.safe_dump(data.model_dump(), allow_unicode=True, sort_keys=False),
            encoding="utf-8",
        )
        return {"status": "ok"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
