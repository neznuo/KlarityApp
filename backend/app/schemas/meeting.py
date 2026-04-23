"""Meeting Pydantic schemas."""

from __future__ import annotations
from typing import Optional

from datetime import datetime
from pathlib import Path

from pydantic import BaseModel, Field, field_validator


class MeetingCreate(BaseModel):
    title: str = Field(..., max_length=200)
    calendar_event_id: Optional[str] = None
    calendar_source: Optional[str] = None


class MeetingStatusUpdate(BaseModel):
    status: str


class MeetingPatch(BaseModel):
    title: Optional[str] = None
    audio_file_path: Optional[str] = None
    ended_at: Optional[datetime] = None
    duration_seconds: Optional[float] = None
    calendar_event_id: Optional[str] = None
    calendar_source: Optional[str] = None

    @field_validator("audio_file_path")
    @classmethod
    def _validate_audio_path(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return v
        from app.core.config import settings
        resolved = Path(v).expanduser().resolve()
        allowed_base = settings.meetings_path.resolve()
        if not str(resolved).startswith(str(allowed_base)):
            raise ValueError("audio_file_path must resolve inside the configured meetings directory")
        return v


class MeetingOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    title: str
    started_at: Optional[datetime]
    ended_at: Optional[datetime]
    duration_seconds: Optional[float]
    status: str
    audio_file_path: Optional[str]
    normalized_audio_path: Optional[str]
    transcript_json_path: Optional[str]
    summary_json_path: Optional[str]
    calendar_event_id: Optional[str]
    calendar_source: Optional[str]
    created_at: datetime
    updated_at: datetime


class MeetingListOut(BaseModel):
    model_config = {"from_attributes": True, "populate_by_name": True}

    id: str
    title: str
    started_at: Optional[datetime]
    ended_at: Optional[datetime]
    duration_seconds: Optional[float]
    status: str
    created_at: datetime
    speakers_preview: list[str] = []  # display names of identified people in this meeting
