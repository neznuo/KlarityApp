-- Klarity App — SQLite Schema (reference / documentation)
-- The authoritative schema is managed by SQLAlchemy / init_db().
-- This file exists for human reference and can be used for manual inspection.

CREATE TABLE IF NOT EXISTS meetings (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    started_at DATETIME,
    ended_at DATETIME,
    duration_seconds REAL,
    status TEXT NOT NULL DEFAULT 'created',
    -- status values: created | recording | preprocessing | transcribing |
    --   matching_speakers | transcript_ready | summarizing | complete | failed
    audio_file_path TEXT,
    normalized_audio_path TEXT,
    transcript_json_path TEXT,
    summary_json_path TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS people (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    notes TEXT,
    last_seen_at DATETIME,
    meeting_count INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS person_embeddings (
    id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    embedding_path TEXT,           -- path to .npy file with the embedding vector
    source_meeting_id TEXT REFERENCES meetings(id),
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS speaker_clusters (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    temp_label TEXT NOT NULL,      -- e.g. "Speaker_1"
    assigned_person_id TEXT REFERENCES people(id),
    confidence REAL,
    duration_seconds REAL,
    segment_count INTEGER NOT NULL DEFAULT 0,
    duplicate_group_hint TEXT,     -- label of cluster this may be a duplicate of
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS transcript_segments (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    cluster_id TEXT REFERENCES speaker_clusters(id),
    start_ms INTEGER NOT NULL,     -- milliseconds from meeting start
    end_ms INTEGER NOT NULL,
    text TEXT NOT NULL,
    confidence REAL,
    audio_snippet_path TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS summaries (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,        -- e.g. "openai", "ollama"
    model TEXT NOT NULL,
    summary_markdown TEXT,
    summary_json TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    owner_person_id TEXT REFERENCES people(id),
    raw_owner_text TEXT,
    description TEXT NOT NULL,
    due_date DATE,
    status TEXT NOT NULL DEFAULT 'open',  -- open | done
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS processing_jobs (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    job_type TEXT NOT NULL,        -- preprocess | transcribe | embed | summarize
    status TEXT NOT NULL DEFAULT 'pending',  -- pending | running | done | failed
    error_message TEXT,
    started_at DATETIME,
    finished_at DATETIME,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
