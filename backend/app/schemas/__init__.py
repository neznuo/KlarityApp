"""
Pydantic v2 request/response schemas.
All schemas are re-exported from here for convenience.
"""

from app.schemas.meeting import (
    MeetingCreate,
    MeetingOut,
    MeetingListOut,
    MeetingStatusUpdate,
)
from app.schemas.person import PersonCreate, PersonUpdate, PersonOut
from app.schemas.speaker import (
    SpeakerClusterOut,
    AssignSpeakerRequest,
    MergeSpeakersRequest,
)
from app.schemas.transcript import TranscriptSegmentOut
from app.schemas.summary import SummaryOut, GenerateSummaryRequest
from app.schemas.task import TaskOut
from app.schemas.settings import SettingsOut, SettingsPatch

__all__ = [
    "MeetingCreate", "MeetingOut", "MeetingListOut", "MeetingStatusUpdate",
    "PersonCreate", "PersonUpdate", "PersonOut",
    "SpeakerClusterOut", "AssignSpeakerRequest", "MergeSpeakersRequest",
    "TranscriptSegmentOut",
    "SummaryOut", "GenerateSummaryRequest",
    "TaskOut",
    "SettingsOut", "SettingsPatch",
]
