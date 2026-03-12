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
