"""Settings Pydantic schemas."""

from __future__ import annotations

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
    elevenlabs_api_key: str | None = None
    openai_api_key: str | None = None
    anthropic_api_key: str | None = None
    gemini_api_key: str | None = None
    ollama_endpoint: str | None = None
    default_llm_provider: str | None = None
    default_llm_model: str | None = None
    default_transcription_provider: str | None = None
    base_storage_dir: str | None = None
    speaker_suggest_threshold: float | None = None
    speaker_auto_assign_threshold: float | None = None
    speaker_duplicate_threshold: float | None = None
    google_calendar_connected: bool | None = None
    outlook_connected: bool | None = None
