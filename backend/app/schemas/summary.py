"""Summary Pydantic schemas."""

from __future__ import annotations
from typing import Literal, Optional

from datetime import datetime

from pydantic import BaseModel, Field


class GenerateSummaryRequest(BaseModel):
    provider: Literal["openai", "ollama", "anthropic", "gemini"] = "ollama"
    model: str = Field(default="llama3", max_length=100)


class SummaryOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    meeting_id: str
    provider: str
    model: str
    summary_markdown: Optional[str]
    summary_json: Optional[str]
    created_at: datetime
