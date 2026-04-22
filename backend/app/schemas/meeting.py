"""Meeting Pydantic schemas."""

from __future__ import annotations
from typing import Optional

from datetime import datetime

from pydantic import BaseModel


class MeetingCreate(BaseModel):
    title: str
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
