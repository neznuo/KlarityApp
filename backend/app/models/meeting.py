"""Meeting ORM model."""

from __future__ import annotations

import uuid
from datetime import datetime

from typing import Optional
from sqlalchemy import DateTime, Float, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.database import Base


class Meeting(Base):
    __tablename__ = "meetings"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    title: Mapped[str] = mapped_column(String, nullable=False)
    started_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    ended_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    duration_seconds: Mapped[Optional[float]] = mapped_column(Float, nullable=True)

    # Status lifecycle:
    # created → recording → preprocessing → transcribing →
    # matching_speakers → transcript_ready → summarizing → complete | failed
    status: Mapped[str] = mapped_column(String, nullable=False, default="created")

    audio_file_path: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    normalized_audio_path: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    transcript_json_path: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    summary_json_path: Mapped[Optional[str]] = mapped_column(String, nullable=True)

    calendar_event_id: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    calendar_source: Mapped[Optional[str]] = mapped_column(String, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime, default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=func.now(), onupdate=func.now(), nullable=False
    )
