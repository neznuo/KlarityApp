"""
Core application configuration.
Reads settings from environment variables / .env file.
"""

from __future__ import annotations

import os
from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # Server
    backend_host: str = "127.0.0.1"
    backend_port: int = 8765
    log_level: str = "INFO"

    # Storage
    base_storage_dir: str = "~/Documents/AI-Meetings"

    @property
    def storage_path(self) -> Path:
        return Path(self.base_storage_dir).expanduser().resolve()

    @property
    def meetings_path(self) -> Path:
        return self.storage_path / "meetings"

    @property
    def voices_path(self) -> Path:
        return self.storage_path / "voices"

    @property
    def exports_path(self) -> Path:
        return self.storage_path / "exports"

    @property
    def logs_path(self) -> Path:
        return self.storage_path / "logs"

    @property
    def db_path(self) -> Path:
        return self.storage_path / "app.db"

    # Transcription
    elevenlabs_api_key: str = ""
    default_transcription_provider: str = "elevenlabs"

    # LLM Providers
    openai_api_key: str = ""
    anthropic_api_key: str = ""
    gemini_api_key: str = ""
    ollama_endpoint: str = "http://localhost:11434"
    default_llm_provider: str = "ollama"
    default_llm_model: str = "llama3"

    # Speaker Matching Thresholds
    speaker_suggest_threshold: float = 0.65
    speaker_auto_assign_threshold: float = 0.80
    speaker_duplicate_threshold: float = 0.75

    # Calendar integrations (connection state stored in-memory; updated by Swift via PATCH /settings)
    google_calendar_connected: bool = False
    outlook_connected: bool = False


# Singleton instance consumed throughout the app
settings = Settings()


def ensure_storage_dirs() -> None:
    """Create required local storage directories if they don't exist."""
    for path in [
        settings.storage_path,
        settings.meetings_path,
        settings.voices_path,
        settings.exports_path,
        settings.logs_path,
    ]:
        path.mkdir(parents=True, exist_ok=True)
