"""SpeakerCluster ORM model — meeting-local temporary speaker grouping."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, Float, ForeignKey, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.database import Base


class SpeakerCluster(Base):
    __tablename__ = "speaker_clusters"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    meeting_id: Mapped[str] = mapped_column(
        String, ForeignKey("meetings.id", ondelete="CASCADE"), nullable=False
    )
    temp_label: Mapped[str] = mapped_column(String, nullable=False)  # e.g. "Speaker_1"
    assigned_person_id: Mapped[str | None] = mapped_column(
        String, ForeignKey("people.id"), nullable=True
    )
    confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    duration_seconds: Mapped[float | None] = mapped_column(Float, nullable=True)
    segment_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    suggested_person_id: Mapped[str | None] = mapped_column(
        String, ForeignKey("people.id"), nullable=True
    )
    duplicate_group_hint: Mapped[str | None] = mapped_column(String, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime, default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=func.now(), onupdate=func.now(), nullable=False
    )
