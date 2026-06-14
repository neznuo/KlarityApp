"""Local filesystem storage layout helpers."""

from __future__ import annotations
from typing import Optional

import re
from pathlib import Path

from app.core.config import settings


def slugify(text: str) -> str:
    """Convert a string to a safe directory name slug."""
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"[\s_-]+", "-", text)


def get_meeting_dir(meeting_id: str, title: Optional[str] = None) -> Path:
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


def resolve_audio_for_embedding(meeting_id: str, normalized_path_str: Optional[str]) -> Optional[Path]:
    """Return the best available audio file for speaker embedding.

    Prefers normalized.wav (already 16kHz mono), falls back to audio.wav when
    normalized has been cleaned up after processing completes.
    """
    if normalized_path_str:
        p = Path(normalized_path_str)
        if p.exists():
            return p
    fallback = audio_path(meeting_id)
    return fallback if fallback.exists() else None


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
    """Mean embedding for a person — used for matching. Updated on every confirmation."""
    path = settings.voices_path / f"{person_id}.npy"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def voice_sample_path(person_id: str, meeting_id: str) -> Path:
    """Per-meeting voice sample for a person — accumulated for averaging."""
    path = settings.voices_path / f"{person_id}_{meeting_id}.npy"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path
