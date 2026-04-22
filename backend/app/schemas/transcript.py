"""TranscriptSegment Pydantic schema."""

from __future__ import annotations
from typing import Optional

from pydantic import BaseModel


class TranscriptSegmentOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    meeting_id: str
    cluster_id: Optional[str]
    # Resolved display name from the cluster → person assignment, if available
    speaker_label: Optional[str] = None
    start_ms: int
    end_ms: int
    text: str
    confidence: Optional[float]
