"""Speaker cluster Pydantic schemas."""

from __future__ import annotations
from typing import Optional

from pydantic import BaseModel


class SpeakerClusterOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    meeting_id: str
    temp_label: str
    assigned_person_id: Optional[str]
    suggested_person_id: Optional[str] = None
    suggested_person_name: Optional[str] = None
    confidence: Optional[float]
    duration_seconds: Optional[float]
    segment_count: int
    duplicate_group_hint: Optional[str]


class AssignSpeakerRequest(BaseModel):
    cluster_id: str
    person_id: Optional[str] = None      # None means create a new person
    new_person_name: Optional[str] = None  # Used when person_id is None


class ConfirmSuggestionRequest(BaseModel):
    cluster_id: str


class MergeSpeakersRequest(BaseModel):
    source_cluster_ids: list[str]     # clusters to merge FROM
    target_cluster_id: str            # cluster to merge INTO
    target_person_id: Optional[str] = None
    new_person_name: Optional[str] = None
