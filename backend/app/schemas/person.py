"""Person Pydantic schemas."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class PersonCreate(BaseModel):
    display_name: str
    notes: str | None = None


class PersonUpdate(BaseModel):
    display_name: str | None = None
    notes: str | None = None


class PersonOut(BaseModel):
    model_config = {"from_attributes": True, "populate_by_name": True}

    id: str
    display_name: str
    notes: str | None
    last_seen_at: datetime | None
    meeting_count: int
    created_at: datetime
    updated_at: datetime
    has_voice_embedding: bool = False   # True when a .npy voice file exists for this person
