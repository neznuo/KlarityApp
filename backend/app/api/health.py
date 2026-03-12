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


@router.get("/health/dependencies")
def check_dependencies():
    """
    Probe all runtime dependencies required for the processing pipeline.
    Returns a list of checks with status 'ok' | 'missing' | 'not_configured'.
    """
    from app.services.audio.preprocessor import find_tool_or_none

    checks = []

    # ── System tools ────────────────────────────────────────────────────────
    ffmpeg_path = find_tool_or_none("ffmpeg")
    checks.append({
        "key": "ffmpeg",
        "name": "FFmpeg",
        "status": "ok" if ffmpeg_path else "missing",
        "detail": ffmpeg_path if ffmpeg_path else "Not found — run: brew install ffmpeg",
        "required": True,
    })

    ffprobe_path = find_tool_or_none("ffprobe")
    checks.append({
        "key": "ffprobe",
        "name": "FFprobe",
        "status": "ok" if ffprobe_path else "missing",
        "detail": ffprobe_path if ffprobe_path else "Not found — run: brew install ffmpeg",
        "required": True,
    })

    # ── Transcription ────────────────────────────────────────────────────────
    has_eleven = bool(settings.elevenlabs_api_key)
    checks.append({
        "key": "elevenlabs_api_key",
        "name": "ElevenLabs API Key",
        "status": "ok" if has_eleven else "not_configured",
        "detail": "Configured" if has_eleven else "Missing — add your key in Settings → Transcription",
        "required": True,
    })

    # ── LLM provider ─────────────────────────────────────────────────────────
    active_llm = next(
        (p for p, v in [
            ("OpenAI", settings.openai_api_key),
            ("Anthropic", settings.anthropic_api_key),
            ("Gemini", settings.gemini_api_key),
            ("Ollama", settings.ollama_endpoint),
        ] if v),
        None,
    )
    checks.append({
        "key": "llm_provider",
        "name": "LLM Provider",
        "status": "ok" if active_llm else "not_configured",
        "detail": f"Using {active_llm}" if active_llm else "No provider configured — add an API key or Ollama endpoint",
        "required": False,
    })

    all_required_ok = all(c["status"] == "ok" for c in checks if c["required"])
    return {"all_required_ok": all_required_ok, "checks": checks}


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
