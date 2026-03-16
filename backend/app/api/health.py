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

    # ── Speaker recognition (Resemblyzer + webrtcvad) ────────────────────────
    # webrtcvad calls `import pkg_resources` which requires setuptools<80.
    # We do a live import to catch this exact failure mode.
    resemblyzer_status, resemblyzer_detail = _check_resemblyzer()
    checks.append({
        "key": "resemblyzer",
        "name": "Speaker Recognition (Resemblyzer)",
        "status": resemblyzer_status,
        "detail": resemblyzer_detail,
        "required": False,   # App works without it; only speaker auto-match is degraded
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
    # Check cloud providers first (key presence is sufficient)
    cloud_provider = next(
        (p for p, v in [
            ("OpenAI", settings.openai_api_key),
            ("Anthropic", settings.anthropic_api_key),
            ("Gemini", settings.gemini_api_key),
        ] if v),
        None,
    )

    if cloud_provider:
        checks.append({
            "key": "llm_provider",
            "name": "LLM Provider",
            "status": "ok",
            "detail": f"Using {cloud_provider}",
            "required": False,
        })
    elif settings.ollama_endpoint:
        # Ollama: verify endpoint is reachable AND the configured model is pulled
        import httpx as _httpx
        ollama_status, ollama_detail = _check_ollama(
            settings.ollama_endpoint, settings.default_llm_model
        )
        checks.append({
            "key": "llm_provider",
            "name": "LLM Provider (Ollama)",
            "status": ollama_status,
            "detail": ollama_detail,
            "required": False,
        })
    else:
        checks.append({
            "key": "llm_provider",
            "name": "LLM Provider",
            "status": "not_configured",
            "detail": "No provider configured — add an API key or Ollama endpoint in Settings",
            "required": False,
        })

    all_required_ok = all(c["status"] == "ok" for c in checks if c["required"])
    return {"all_required_ok": all_required_ok, "checks": checks}


@router.get("/health/ollama/models")
def list_ollama_models():
    """Return the list of models pulled in the configured Ollama instance."""
    if not settings.ollama_endpoint:
        return {"models": []}
    import httpx
    try:
        resp = httpx.get(
            f"{settings.ollama_endpoint.rstrip('/')}/api/tags", timeout=5.0
        )
        if resp.status_code != 200:
            return {"models": []}
        return {"models": [m["name"] for m in resp.json().get("models", [])]}
    except Exception:
        return {"models": []}


def _check_resemblyzer() -> tuple[str, str]:
    """
    Try to import resemblyzer end-to-end.
    webrtcvad (a resemblyzer dep) calls `import pkg_resources` which requires
    setuptools<80 — this check catches that failure mode explicitly.
    Returns (status, detail).
    """
    try:
        from resemblyzer import preprocess_wav, VoiceEncoder  # noqa: F401
        return "ok", "Resemblyzer available — speaker recognition enabled"
    except ModuleNotFoundError as exc:
        if "pkg_resources" in str(exc):
            return "missing", (
                "pkg_resources not found — run: pip install 'setuptools<80' "
                "(webrtcvad requires setuptools < 80)"
            )
        return "missing", f"resemblyzer not installed: {exc}"
    except Exception as exc:
        return "missing", f"resemblyzer import failed: {exc}"


def _check_ollama(endpoint: str, model: str) -> tuple[str, str]:
    """
    Probe the Ollama endpoint and verify the configured model is pulled.
    Returns (status, detail) where status is 'ok' | 'missing' | 'not_configured'.
    """
    import httpx
    base = endpoint.rstrip("/")
    try:
        resp = httpx.get(f"{base}/api/tags", timeout=5.0)
        if resp.status_code != 200:
            return "missing", f"Ollama unreachable at {base} (HTTP {resp.status_code})"
        available = [m["name"] for m in resp.json().get("models", [])]
        # Accept exact match or tag-less match (e.g. "qwen3:4b" matches "qwen3:4b")
        if model in available or any(m.split(":")[0] == model.split(":")[0] for m in available):
            return "ok", f"{model} available at {base}"
        return "not_configured", (
            f"Model '{model}' not pulled. Run: ollama pull {model}\n"
            f"Available: {', '.join(available) or 'none'}"
        )
    except Exception as exc:
        return "missing", f"Cannot reach Ollama at {base}: {exc}"


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
        google_calendar_connected=settings.google_calendar_connected,
        outlook_connected=settings.outlook_connected,
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
