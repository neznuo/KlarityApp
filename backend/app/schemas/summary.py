"""Summary Pydantic schemas."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class GenerateSummaryRequest(BaseModel):
    provider: str = "ollama"   # openai | ollama | anthropic | gemini
    model: str = "llama3"


class SummaryOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    meeting_id: str
    provider: str
    model: str
    summary_markdown: str | None
    summary_json: str | None
    created_at: datetime
