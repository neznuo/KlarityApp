"""Person and PersonEmbedding ORM models."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.database import Base


class Person(Base):
    __tablename__ = "people"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    display_name: Mapped[str] = mapped_column(String, nullable=False)
    notes: Mapped[str | None] = mapped_column(String, nullable=True)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    meeting_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    created_at: Mapped[datetime] = mapped_column(DateTime, default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=func.now(), onupdate=func.now(), nullable=False
    )

    embeddings: Mapped[list[PersonEmbedding]] = relationship(
        "PersonEmbedding", back_populates="person", cascade="all, delete-orphan"
    )


class PersonEmbedding(Base):
    __tablename__ = "person_embeddings"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    person_id: Mapped[str] = mapped_column(
        String, ForeignKey("people.id", ondelete="CASCADE"), nullable=False
    )
    embedding_path: Mapped[str | None] = mapped_column(String, nullable=True)
    source_meeting_id: Mapped[str | None] = mapped_column(
        String, ForeignKey("meetings.id"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime, default=func.now(), nullable=False)

    person: Mapped[Person] = relationship("Person", back_populates="embeddings")
