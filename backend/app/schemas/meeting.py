"""Meeting Pydantic schemas."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class MeetingCreate(BaseModel):
    title: str


class MeetingStatusUpdate(BaseModel):
    status: str


class MeetingOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    title: str
    started_at: datetime | None
    ended_at: datetime | None
    duration_seconds: float | None
    status: str
    audio_file_path: str | None
    normalized_audio_path: str | None
    transcript_json_path: str | None
    summary_json_path: str | None
    created_at: datetime
    updated_at: datetime


class MeetingListOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    title: str
    started_at: datetime | None
    ended_at: datetime | None
    duration_seconds: float | None
    status: str
    created_at: datetime
