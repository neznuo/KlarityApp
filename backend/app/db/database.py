"""
SQLAlchemy engine, session factory, and Base declaration.
"""

from __future__ import annotations

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.core.config import settings


def get_database_url() -> str:
    db_path = settings.db_path
    db_path.parent.mkdir(parents=True, exist_ok=True)
    return f"sqlite:///{db_path}"


engine = create_engine(
    get_database_url(),
    connect_args={"check_same_thread": False},
    echo=False,
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


def get_db():
    """FastAPI dependency — yields a database session."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db() -> None:
    """Create all tables defined with Base if they don't already exist."""
    # Import models so they register with Base.metadata
    import app.models  # noqa: F401
    Base.metadata.create_all(bind=engine)

    # SQLite migration: add calendar columns to meetings if missing
    from sqlalchemy import text
    from sqlalchemy.exc import OperationalError

    with engine.connect() as conn:
        for col in ("calendar_event_id VARCHAR", "calendar_source VARCHAR"):
            try:
                conn.execute(text(f"ALTER TABLE meetings ADD COLUMN {col}"))
                conn.commit()
            except OperationalError:
                pass  # Column already exists
