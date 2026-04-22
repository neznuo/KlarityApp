"""Summary Pydantic schemas."""

from __future__ import annotations
from typing import Optional

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
    summary_markdown: Optional[str]
    summary_json: Optional[str]
    created_at: datetime
