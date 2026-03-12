"""
SQLAlchemy ORM models.
All models are imported here so init_db() can discover them via Base.metadata.
"""

from app.models.meeting import Meeting
from app.models.person import Person, PersonEmbedding
from app.models.speaker import SpeakerCluster
from app.models.transcript import TranscriptSegment
from app.models.summary import Summary
from app.models.task import Task
from app.models.setting import Setting
from app.models.job import ProcessingJob

__all__ = [
    "Meeting",
    "Person",
    "PersonEmbedding",
    "SpeakerCluster",
    "TranscriptSegment",
    "Summary",
    "Task",
    "Setting",
    "ProcessingJob",
]
