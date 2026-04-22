"""Task ORM model — action items extracted from meeting summaries."""

from __future__ import annotations

import uuid
from datetime import date, datetime

from typing import Optional
from sqlalchemy import Date, DateTime, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.database import Base


class Task(Base):
    __tablename__ = "tasks"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    meeting_id: Mapped[str] = mapped_column(
        String, ForeignKey("meetings.id", ondelete="CASCADE"), nullable=False
    )
    owner_person_id: Mapped[Optional[str]] = mapped_column(
        String, ForeignKey("people.id"), nullable=True
    )
    raw_owner_text: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    description: Mapped[str] = mapped_column(Text, nullable=False)
    due_date: Mapped[Optional[date]] = mapped_column(Date, nullable=True)
    status: Mapped[str] = mapped_column(String, nullable=False, default="open")  # open | done

    created_at: Mapped[datetime] = mapped_column(DateTime, default=func.now(), nullable=False)
