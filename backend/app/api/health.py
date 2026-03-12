"""Health check and settings routers."""

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.core.config import settings
from app.db.database import get_db
from app.schemas import SettingsOut, SettingsPatch

router = APIRouter(tags=["health"])


@router.get("/health")
def health_check():
    """Liveness probe endpoint."""
    return {"status": "ok", "service": "klarity-backend"}


@router.get("/settings", response_model=SettingsOut)
def get_settings():
    """Return current effective settings."""
    return SettingsOut(
        elevenlabs_api_key=settings.elevenlabs_api_key,
        openai_api_key=settings.openai_api_key,
        anthropic_api_key=settings.anthropic_api_key,
        gemini_api_key=settings.gemini_api_key,
        ollama_endpoint=settings.ollama_endpoint,
        default_llm_provider=settings.default_llm_provider,
        default_llm_model=settings.default_llm_model,
        default_transcription_provider=settings.default_transcription_provider,
        base_storage_dir=str(settings.storage_path),
        speaker_suggest_threshold=settings.speaker_suggest_threshold,
        speaker_auto_assign_threshold=settings.speaker_auto_assign_threshold,
        speaker_duplicate_threshold=settings.speaker_duplicate_threshold,
    )


@router.patch("/settings", response_model=SettingsOut)
def patch_settings(body: SettingsPatch, db: Session = Depends(get_db)):
    """
    Update runtime settings.
    NOTE: In a real implementation this would write values to the DB settings
    table or reload environment — this stub just echoes what was sent merged
    with current values.
    """
    from app.models.setting import Setting
    from datetime import datetime, timezone

    updates = body.model_dump(exclude_none=True)
    for key, value in updates.items():
        row = db.get(Setting, key)
        if row:
            row.value = str(value)
            row.updated_at = datetime.now(timezone.utc)
        else:
            row = Setting(key=key, value=str(value))
            db.add(row)
    db.commit()

    # Reload the in-memory settings from DB values
    for key, value in updates.items():
        if hasattr(settings, key):
            try:
                setattr(settings, key, type(getattr(settings, key))(value))
            except Exception:
                pass

    return get_settings()
