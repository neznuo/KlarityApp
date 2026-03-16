"""Meetings CRUD + processing trigger endpoints."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.database import get_db
from app.models.meeting import Meeting
from app.schemas import MeetingCreate, MeetingListOut, MeetingOut, MeetingPatch

router = APIRouter(prefix="/meetings", tags=["meetings"])


@router.get("", response_model=list[MeetingListOut])
def list_meetings(db: Session = Depends(get_db)):
    """Return all meetings ordered by creation date descending, with identified speaker names."""
    from app.models.person import Person
    from app.models.speaker import SpeakerCluster

    meetings = db.query(Meeting).order_by(Meeting.created_at.desc()).all()
    if not meetings:
        return []

    # Single query: get all assigned person names grouped by meeting_id
    meeting_ids = [m.id for m in meetings]
    rows = (
        db.query(SpeakerCluster.meeting_id, Person.display_name)
        .join(Person, SpeakerCluster.assigned_person_id == Person.id)
        .filter(SpeakerCluster.meeting_id.in_(meeting_ids))
        .all()
    )
    speakers_by_meeting: dict[str, list[str]] = {}
    seen: set[tuple] = set()
    for mid, name in rows:
        if (mid, name) not in seen:
            speakers_by_meeting.setdefault(mid, []).append(name)
            seen.add((mid, name))

    result = []
    for m in meetings:
        out = MeetingListOut.model_validate(m)
        out.speakers_preview = speakers_by_meeting.get(m.id, [])[:4]
        result.append(out)
    return result


@router.post("", response_model=MeetingOut, status_code=201)
def create_meeting(body: MeetingCreate, db: Session = Depends(get_db)):
    """Create a new meeting record. Called when the user hits Start Recording."""
    meeting = Meeting(
        id=str(uuid.uuid4()),
        title=body.title,
        started_at=datetime.now(timezone.utc),
        status="recording",
        calendar_event_id=body.calendar_event_id,
        calendar_source=body.calendar_source,
    )
    db.add(meeting)
    db.commit()
    db.refresh(meeting)
    return meeting

@router.patch("/{meeting_id}", response_model=MeetingOut)
def update_meeting(meeting_id: str, body: MeetingPatch, db: Session = Depends(get_db)):
    """Update meeting metadata, such as setting the audio file path after recording stops."""
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    if body.title is not None:
        meeting.title = body.title
    if body.audio_file_path is not None:
        meeting.audio_file_path = body.audio_file_path
    if body.ended_at is not None:
        meeting.ended_at = body.ended_at
    if body.duration_seconds is not None:
        meeting.duration_seconds = body.duration_seconds
    if body.calendar_event_id is not None:
        meeting.calendar_event_id = body.calendar_event_id
    if body.calendar_source is not None:
        meeting.calendar_source = body.calendar_source

    meeting.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(meeting)
    return meeting


@router.get("/{meeting_id}", response_model=MeetingOut)
def get_meeting(meeting_id: str, db: Session = Depends(get_db)):
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")
    return meeting


@router.delete("/{meeting_id}", status_code=204)
def delete_meeting(meeting_id: str, db: Session = Depends(get_db)):
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")
    db.delete(meeting)
    db.commit()


@router.post("/{meeting_id}/process")
def trigger_processing(
    meeting_id: str,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """
    Trigger the full processing pipeline for a recorded meeting.
    Runs asynchronously in a background task.
    """
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")
    if not meeting.audio_file_path:
        raise HTTPException(status_code=400, detail="No audio file path set on this meeting")

    from app.workers.processing_worker import run_processing_pipeline
    background_tasks.add_task(run_processing_pipeline, meeting_id)
    return {"message": "Processing started", "meeting_id": meeting_id}


@router.post("/{meeting_id}/reprocess-summary")
def reprocess_summary(
    meeting_id: str,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """Re-generate the summary using the current settings provider."""
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    from app.workers.processing_worker import run_summarization_step
    background_tasks.add_task(run_summarization_step, meeting_id)
    return {"message": "Summary regeneration started", "meeting_id": meeting_id}


@router.post("/{meeting_id}/recompute-speaker-suggestions")
def recompute_speakers(
    meeting_id: str,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """Re-run the speaker matching step against the known people library."""
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    from app.workers.processing_worker import run_speaker_matching_step
    background_tasks.add_task(run_speaker_matching_step, meeting_id)
    return {"message": "Speaker suggestion recompute started", "meeting_id": meeting_id}
