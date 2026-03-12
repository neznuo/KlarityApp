"""Task Pydantic schema."""

from __future__ import annotations

from datetime import date, datetime

from pydantic import BaseModel


class TaskOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    meeting_id: str
    owner_person_id: str | None
    raw_owner_text: str | None
    description: str
    due_date: date | None
    status: str
    created_at: datetime
