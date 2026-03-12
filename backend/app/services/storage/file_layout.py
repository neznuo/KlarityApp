"""Local filesystem storage layout helpers."""

from __future__ import annotations

import re
from pathlib import Path

from app.core.config import settings


def slugify(text: str) -> str:
    """Convert a string to a safe directory name slug."""
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"[\s_-]+", "-", text)


def get_meeting_dir(meeting_id: str, title: str | None = None) -> Path:
    """
    Return (and create) the directory for a specific meeting.
    Uses meeting_id as the folder name — clean and collision-free.
    """
    base = settings.meetings_path / meeting_id
    base.mkdir(parents=True, exist_ok=True)
    return base


def audio_path(meeting_id: str) -> Path:
    return get_meeting_dir(meeting_id) / "audio.wav"


def normalized_audio_path(meeting_id: str) -> Path:
    return get_meeting_dir(meeting_id) / "normalized.wav"


def transcript_raw_json_path(meeting_id: str) -> Path:
    return get_meeting_dir(meeting_id) / "transcript.raw.json"


def transcript_json_path(meeting_id: str) -> Path:
    return get_meeting_dir(meeting_id) / "transcript.json"


def transcript_md_path(meeting_id: str) -> Path:
    return get_meeting_dir(meeting_id) / "transcript.md"


def summary_json_path(meeting_id: str) -> Path:
    return get_meeting_dir(meeting_id) / "summary.json"


def summary_md_path(meeting_id: str) -> Path:
    return get_meeting_dir(meeting_id) / "summary.md"


def tasks_json_path(meeting_id: str) -> Path:
    return get_meeting_dir(meeting_id) / "tasks.json"


def voice_embedding_path(person_id: str) -> Path:
    path = settings.voices_path / f"{person_id}.npy"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path
