"""Speaker cluster Pydantic schemas."""

from __future__ import annotations

from pydantic import BaseModel


class SpeakerClusterOut(BaseModel):
    model_config = {"from_attributes": True}

    id: str
    meeting_id: str
    temp_label: str
    assigned_person_id: str | None
    suggested_person_id: str | None = None
    suggested_person_name: str | None = None
    confidence: float | None
    duration_seconds: float | None
    segment_count: int
    duplicate_group_hint: str | None


class AssignSpeakerRequest(BaseModel):
    cluster_id: str
    person_id: str | None = None      # None means create a new person
    new_person_name: str | None = None  # Used when person_id is None


class ConfirmSuggestionRequest(BaseModel):
    cluster_id: str


class MergeSpeakersRequest(BaseModel):
    source_cluster_ids: list[str]     # clusters to merge FROM
    target_cluster_id: str            # cluster to merge INTO
    target_person_id: str | None = None
    new_person_name: str | None = None
