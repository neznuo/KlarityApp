"""Task Pydantic schema."""

from __future__ import annotations
from typing import Literal, Optional

from datetime import date, datetime

from pydantic import BaseModel


class TaskOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    meeting_id: str
    meeting_title: Optional[str] = None
    owner_person_id: Optional[str]
    raw_owner_text: Optional[str]
    description: str
    due_date: Optional[date]
    status: str
    created_at: datetime

class TaskUpdate(BaseModel):
    status: Optional[Literal["open", "done"]] = None
    description: Optional[str] = None
    raw_owner_text: Optional[str] = None
    owner_person_id: Optional[str] = None
