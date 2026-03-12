"""TranscriptSegment Pydantic schema."""

from __future__ import annotations

from pydantic import BaseModel


class TranscriptSegmentOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    meeting_id: str
    cluster_id: str | None
    # Resolved display name from the cluster → person assignment, if available
    speaker_label: str | None = None
    start_ms: int
    end_ms: int
    text: str
    confidence: float | None
