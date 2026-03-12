"""Summary generation and retrieval endpoints."""

from __future__ import annotations

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.database import get_db
from app.models.meeting import Meeting
from app.models.summary import Summary
from app.models.task import Task
from app.schemas import GenerateSummaryRequest, SummaryOut, TaskOut

router = APIRouter(prefix="/meetings", tags=["summaries"])


@router.get("/{meeting_id}/summary", response_model=SummaryOut | None)
def get_summary(meeting_id: str, db: Session = Depends(get_db)):
    """Return the latest summary for a meeting, or null if not yet generated."""
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")
    summary = (
        db.query(Summary)
        .filter(Summary.meeting_id == meeting_id)
        .order_by(Summary.created_at.desc())
        .first()
    )
    return summary


@router.post("/{meeting_id}/generate-summary")
def generate_summary(
    meeting_id: str,
    body: GenerateSummaryRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """
    Manually trigger summary + task generation.
    This is ALWAYS user-initiated — never called automatically.
    """
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    from app.workers.processing_worker import run_summarization_step
    background_tasks.add_task(
        run_summarization_step, meeting_id, body.provider, body.model
    )
    return {"message": "Summary generation started", "provider": body.provider, "model": body.model}


@router.get("/{meeting_id}/tasks", response_model=list[TaskOut])
def get_tasks(meeting_id: str, db: Session = Depends(get_db)):
    """Return tasks extracted for a meeting."""
    return db.query(Task).filter(Task.meeting_id == meeting_id).all()


@router.post("/{meeting_id}/export")
def export_meeting(meeting_id: str, fmt: str = "markdown", db: Session = Depends(get_db)):
    """
    Export meeting artifacts.
    fmt: 'markdown' | 'json'
    Returns the file path of the exported artifact.
    """
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    from app.services.storage.file_layout import get_meeting_dir
    meeting_dir = get_meeting_dir(meeting_id)
    if fmt == "json":
        export_path = meeting_dir / "transcript.json"
    else:
        export_path = meeting_dir / "transcript.md"

    return {"export_path": str(export_path), "format": fmt}
