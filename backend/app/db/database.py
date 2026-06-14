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

        # SQLite migration: add suggested_person_id to speaker_clusters if missing
        try:
            conn.execute(
                text("ALTER TABLE speaker_clusters ADD COLUMN suggested_person_id VARCHAR REFERENCES people(id)")
            )
            conn.commit()
        except OperationalError:
            pass  # Column already exists

        # FTS5: full-text search virtual tables for the AI chat agent
        conn.execute(text("""
            CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
                meeting_id UNINDEXED,
                title,
                summary_text,
                content='',
                tokenize='porter ascii'
            )
        """))
        conn.execute(text("""
            CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
                task_id UNINDEXED,
                meeting_id UNINDEXED,
                description,
                raw_owner_text,
                content='',
                tokenize='porter ascii'
            )
        """))
        conn.commit()

        # Seed FTS tables with existing data (safe: INSERT OR IGNORE won't re-insert)
        conn.execute(text("""
            INSERT OR IGNORE INTO meetings_fts(meeting_id, title, summary_text)
            SELECT m.id, m.title, COALESCE(s.summary_markdown, '')
            FROM meetings m
            LEFT JOIN summaries s ON s.meeting_id = m.id
        """))
        conn.execute(text("""
            INSERT OR IGNORE INTO tasks_fts(task_id, meeting_id, description, raw_owner_text)
            SELECT id, meeting_id, description, COALESCE(raw_owner_text, '')
            FROM tasks
        """))
        conn.commit()
