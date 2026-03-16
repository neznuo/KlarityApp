"""Meeting Pydantic schemas."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class MeetingCreate(BaseModel):
    title: str
    calendar_event_id: str | None = None
    calendar_source: str | None = None


class MeetingStatusUpdate(BaseModel):
    status: str


class MeetingPatch(BaseModel):
    title: str | None = None
    audio_file_path: str | None = None
    ended_at: datetime | None = None
    duration_seconds: float | None = None
    calendar_event_id: str | None = None
    calendar_source: str | None = None


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
    calendar_event_id: str | None
    calendar_source: str | None
    created_at: datetime
    updated_at: datetime


class MeetingListOut(BaseModel):
    model_config = {"from_attributes": True, "populate_by_name": True}

    id: str
    title: str
    started_at: datetime | None
    ended_at: datetime | None
    duration_seconds: float | None
    status: str
    created_at: datetime
    speakers_preview: list[str] = []  # display names of identified people in this meeting
