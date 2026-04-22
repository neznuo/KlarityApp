"""Settings Pydantic schemas."""

from __future__ import annotations
from typing import Optional

from pydantic import BaseModel


class SettingsOut(BaseModel):
    elevenlabs_api_key: str
    openai_api_key: str
    anthropic_api_key: str
    gemini_api_key: str
    ollama_endpoint: str
    default_llm_provider: str
    default_llm_model: str
    default_transcription_provider: str
    base_storage_dir: str
    speaker_suggest_threshold: float
    speaker_auto_assign_threshold: float
    speaker_duplicate_threshold: float
    google_calendar_connected: bool = False
    outlook_connected: bool = False


class SettingsPatch(BaseModel):
    elevenlabs_api_key: Optional[str] = None
    openai_api_key: Optional[str] = None
    anthropic_api_key: Optional[str] = None
    gemini_api_key: Optional[str] = None
    ollama_endpoint: Optional[str] = None
    default_llm_provider: Optional[str] = None
    default_llm_model: Optional[str] = None
    default_transcription_provider: Optional[str] = None
    base_storage_dir: Optional[str] = None
    speaker_suggest_threshold: Optional[float] = None
    speaker_auto_assign_threshold: Optional[float] = None
    speaker_duplicate_threshold: Optional[float] = None
    google_calendar_connected: Optional[bool] = None
    outlook_connected: Optional[bool] = None
