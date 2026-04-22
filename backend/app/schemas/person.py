"""Person Pydantic schemas."""

from __future__ import annotations
from typing import Optional

from datetime import datetime

from pydantic import BaseModel


class PersonCreate(BaseModel):
    display_name: str
    notes: Optional[str] = None


class PersonUpdate(BaseModel):
    display_name: Optional[str] = None
    notes: Optional[str] = None


class PersonOut(BaseModel):
    model_config = {"from_attributes": True, "populate_by_name": True}

    id: str
    display_name: str
    notes: Optional[str]
    last_seen_at: Optional[datetime]
    meeting_count: int
    created_at: datetime
    updated_at: datetime
    has_voice_embedding: bool = False   # True when a .npy voice file exists for this person
