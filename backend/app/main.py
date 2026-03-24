"""
Klarity Backend — FastAPI application entry point.
Run with: uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
"""

from __future__ import annotations

import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import ensure_storage_dirs, settings
from app.db.database import init_db

logging.basicConfig(level=settings.log_level.upper())
logger = logging.getLogger(__name__)


app = FastAPI(
    title="Klarity — Personal AI Meeting Assistant",
    version="0.1.0",
    description="Local-first meeting recording, transcription, and summarization backend.",
)

# Allow the SwiftUI app (localhost) to call the API
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost", "http://127.0.0.1"],
    allow_methods=["*"],
    allow_headers=["*"],
)


from app.db.database import init_db, SessionLocal
from app.models.setting import Setting

@app.on_event("startup")
def on_startup() -> None:
    """Initialize database tables and local storage directories on first boot."""
    logger.info("Klarity backend starting up…")
    ensure_storage_dirs()
    init_db()
    logger.info(f"Storage root: {settings.storage_path}")
    logger.info("Database initialized.")

    # Load settings from Database
    db = SessionLocal()
    try:
        db_settings = db.query(Setting).all()
        for row in db_settings:
            if hasattr(settings, row.key):
                try:
                    setattr(settings, row.key, type(getattr(settings, row.key))(row.value))
                except Exception:
                    pass
    finally:
        db.close()
    logger.info("Loaded runtime settings from DB.")

    _check_embedding_model_version()


def _check_embedding_model_version() -> None:
    """
    Detect stale voice embeddings from a previous model (e.g. resemblyzer).

    Writes a version marker file (voices/embedding_model.txt) on first run.
    If the marker is missing or names a different model, logs a warning so the
    user knows to re-enroll their voice profiles.  Files are never deleted
    automatically — callers use GET /people/embedding-status to check.
    """
    from app.services.embeddings.audio_utils import MODEL_NAME

    marker_path = settings.voices_path / "embedding_model.txt"

    if not marker_path.exists():
        # First run with this model — write the marker
        marker_path.write_text(MODEL_NAME)
        logger.info(f"Speaker embedding model marker written: {MODEL_NAME}")
        return

    stored_model = marker_path.read_text().strip()
    if stored_model != MODEL_NAME:
        logger.warning(
            "Speaker embedding model has changed: stored=%s current=%s. "
            "Existing voice profiles are incompatible and must be re-enrolled. "
            "Use GET /people/embedding-status for details.",
            stored_model,
            MODEL_NAME,
        )
    else:
        logger.info(f"Speaker embedding model verified: {MODEL_NAME}")


# Register all API routers
from app.api import register_routers  # noqa: E402
register_routers(app)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "app.main:app",
        host=settings.backend_host,
        port=settings.backend_port,
        reload=True,
    )
