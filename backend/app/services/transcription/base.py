"""
Transcription provider abstraction.

To add a new provider:
1. Subclass TranscriptionProvider
2. Implement .transcribe()
3. Add to the factory in get_provider()
"""

from __future__ import annotations
from typing import Optional

from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path


@dataclass
class TranscriptWord:
    text: str
    start_ms: int
    end_ms: int
    speaker_id: Optional[str] = None
    confidence: Optional[float] = None


@dataclass
class TranscriptSegment:
    speaker_id: str
    start_ms: int
    end_ms: int
    text: str
    confidence: Optional[float] = None


@dataclass
class TranscriptionResult:
    segments: list[TranscriptSegment]
    raw_response: dict  # provider's raw JSON


class TranscriptionProvider(ABC):
    """Base class for all transcription backends."""

    @abstractmethod
    def transcribe(self, audio_path: Path) -> TranscriptionResult:
        """Transcribe an audio file and return structured segments."""
        ...


def get_provider(name: str) -> TranscriptionProvider:
    """Factory — returns provider by name string."""
    if name == "elevenlabs":
        from app.services.transcription.elevenlabs_provider import ElevenLabsProvider
        return ElevenLabsProvider()
    raise ValueError(f"Unknown transcription provider: {name!r}")
