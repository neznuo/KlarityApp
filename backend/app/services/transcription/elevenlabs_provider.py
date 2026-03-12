"""ElevenLabs Scribe transcription provider."""

from __future__ import annotations

from pathlib import Path

from app.core.config import settings
from app.services.transcription.base import (
    TranscriptionProvider,
    TranscriptionResult,
    TranscriptSegment,
)


class ElevenLabsProvider(TranscriptionProvider):
    """
    Uses the ElevenLabs Scribe API for speech-to-text with speaker diarization.
    Docs: https://elevenlabs.io/docs/speech-to-text
    """

    def transcribe(self, audio_path: Path) -> TranscriptionResult:
        """
        Upload audio to ElevenLabs Scribe and return structured transcript.
        """
        try:
            import httpx
        except ImportError as e:
            raise RuntimeError("httpx is required for ElevenLabsProvider") from e

        api_key = settings.elevenlabs_api_key
        if not api_key:
            raise RuntimeError("ELEVENLABS_API_KEY is not configured.")

        if not audio_path.exists():
            raise FileNotFoundError(f"Audio file not found: {audio_path}")

        with audio_path.open("rb") as f:
            audio_bytes = f.read()

        # ElevenLabs Scribe endpoint
        url = "https://api.elevenlabs.io/v1/speech-to-text"
        headers = {"xi-api-key": api_key}
        files = {"file": (audio_path.name, audio_bytes, "audio/wav")}
        data = {
            "model_id": "scribe_v1",
            "diarize": "true",
        }

        with httpx.Client(timeout=300.0) as client:
            response = client.post(url, headers=headers, files=files, data=data)
            try:
                response.raise_for_status()
            except httpx.HTTPStatusError as exc:
                raise RuntimeError(f"ElevenLabs API Error: {exc.response.text}") from exc

        raw = response.json()
        segments = self._parse_response(raw)
        return TranscriptionResult(segments=segments, raw_response=raw)

    def _parse_response(self, raw: dict) -> list[TranscriptSegment]:
        """Map ElevenLabs Scribe word-level response to internal TranscriptSegment chunks."""
        segments: list[TranscriptSegment] = []
        words = raw.get("words", [])
        if not words:
            return segments

        current_speaker = None
        current_text_parts = []
        start_ms = 0
        end_ms = 0
        confidences = []

        for word in words:
            speaker = word.get("speaker_id", "speaker_0")
            if speaker and not speaker.startswith("Speaker_"):
                # Normalize "speaker_0" or "0" -> "Speaker_0"
                base = speaker.replace("speaker_", "")
                speaker = f"Speaker_{base}"

            w_start = int(word.get("start", 0) * 1000)
            w_end = int(word.get("end", 0) * 1000)
            text = word.get("text", "")
            
            # Map logprob back to pseudo-confidence (0.0 - 1.0)
            import math
            logprob = word.get("logprob", 0)
            conf = math.exp(logprob)

            if current_speaker is None:
                current_speaker = speaker
                start_ms = w_start
                end_ms = w_end
                current_text_parts.append(text)
                confidences.append(conf)
            elif current_speaker == speaker and (w_start - end_ms) < 2000:
                # Same speaker continuing (within 2 seconds)
                end_ms = max(end_ms, w_end)
                current_text_parts.append(text)
                confidences.append(conf)
            else:
                # Speaker paused or changed, yield current segment
                avg_conf = sum(confidences) / len(confidences) if confidences else 1.0
                segments.append(
                    TranscriptSegment(
                        speaker_id=current_speaker,
                        start_ms=start_ms,
                        end_ms=end_ms,
                        text="".join(current_text_parts).strip(),
                        confidence=avg_conf,
                    )
                )
                
                # Start new segment
                current_speaker = speaker
                start_ms = w_start
                end_ms = w_end
                current_text_parts = [text]
                confidences = [conf]

        # Flush final segment
        if current_speaker is not None and current_text_parts:
            avg_conf = sum(confidences) / len(confidences) if confidences else 1.0
            segments.append(
                TranscriptSegment(
                    speaker_id=current_speaker,
                    start_ms=start_ms,
                    end_ms=end_ms,
                    text="".join(current_text_parts).strip(),
                    confidence=avg_conf,
                )
            )

        return segments
