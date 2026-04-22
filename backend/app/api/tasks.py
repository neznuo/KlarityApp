"""Tasks router for Klarity."""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from datetime import datetime, timezone

from app.db.database import get_db
from app.models.task import Task
from app.models.meeting import Meeting
from app.models.person import Person
from app.schemas.task import TaskOut, TaskUpdate

router = APIRouter(prefix="/tasks", tags=["Tasks"])


def _task_to_out(task: Task, db: Session) -> TaskOut:
    """Convert a Task ORM object to TaskOut, resolving the meeting title."""
    meeting = db.get(Meeting, task.meeting_id)
    data = TaskOut.model_validate(task)
    data.meeting_title = meeting.title if meeting else None
    return data


@router.get("", response_model=list[TaskOut])
def list_tasks(db: Session = Depends(get_db)):
    """Retrieve all tasks globally, enriched with meeting titles."""
    tasks = db.query(Task).order_by(Task.created_at.desc()).all()
    return [_task_to_out(t, db) for t in tasks]


@router.patch("/{task_id}", response_model=TaskOut)
def update_task(task_id: str, payload: TaskUpdate, db: Session = Depends(get_db)):
    """Update a specific task (e.g. toggle status)."""
    task = db.get(Task, task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    if payload.status is not None:
        task.status = payload.status
    if payload.description is not None:
        task.description = payload.description
    if payload.raw_owner_text is not None:
        # Empty string means "clear the assignee"
        task.raw_owner_text = payload.raw_owner_text if payload.raw_owner_text.strip() else None

    if payload.owner_person_id is not None:
        if payload.owner_person_id.strip() == "":
            # Unassign: clearing the person FK also clears the display name text
            task.owner_person_id = None
            task.raw_owner_text = None
        else:
            person = db.get(Person, payload.owner_person_id)
            if not person:
                raise HTTPException(status_code=404, detail="Person not found")
            task.owner_person_id = person.id
            task.raw_owner_text = person.display_name

    db.commit()
    db.refresh(task)
    return _task_to_out(task, db)


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_task(task_id: str, db: Session = Depends(get_db)):
    """Permanently delete a task."""
    task = db.get(Task, task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    db.delete(task)
    db.commit()
