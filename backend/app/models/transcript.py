"""TranscriptSegment ORM model."""

from __future__ import annotations

import uuid
from datetime import datetime

from typing import Optional
from sqlalchemy import DateTime, Float, ForeignKey, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.database import Base


class TranscriptSegment(Base):
    __tablename__ = "transcript_segments"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    meeting_id: Mapped[str] = mapped_column(
        String, ForeignKey("meetings.id", ondelete="CASCADE"), nullable=False
    )
    cluster_id: Mapped[Optional[str]] = mapped_column(
        String, ForeignKey("speaker_clusters.id"), nullable=True
    )
    start_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    end_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    text: Mapped[str] = mapped_column(String, nullable=False)
    confidence: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    audio_snippet_path: Mapped[Optional[str]] = mapped_column(String, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime, default=func.now(), nullable=False)
