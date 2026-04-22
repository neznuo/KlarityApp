"""
Tests for task API endpoints — owner_person_id assignment.
Run with: pytest tests/test_tasks.py -v
"""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def _create_meeting(title: str = "Task Test Meeting") -> str:
    resp = client.post("/meetings", json={"title": title})
    assert resp.status_code == 201
    return resp.json()["id"]


def _create_person(display_name: str = "Alice") -> str:
    resp = client.post("/people", json={"display_name": display_name})
    assert resp.status_code == 201
    return resp.json()["id"]


def _create_task(meeting_id: str) -> str:
    """Create a task via the meeting processing pipeline shortcut.

    Since tasks are normally created by the summarization pipeline,
    we insert directly through the DB for test isolation.
    """
    from app.db.database import SessionLocal
    from app.models.task import Task

    db = SessionLocal()
    try:
        task = Task(meeting_id=meeting_id, description="Test action item", status="open")
        db.add(task)
        db.commit()
        db.refresh(task)
        return task.id
    finally:
        db.close()


def test_assign_person_to_task():
    """PATCH /tasks/{id} with owner_person_id sets both FK and raw_owner_text."""
    meeting_id = _create_meeting()
    person_id = _create_person("Bob")
    task_id = _create_task(meeting_id)

    resp = client.patch(f"/tasks/{task_id}", json={"owner_person_id": person_id})
    assert resp.status_code == 200
    data = resp.json()
    assert data["owner_person_id"] == person_id
    assert data["raw_owner_text"] == "Bob"


def test_unassign_person_from_task():
    """PATCH /tasks/{id} with empty owner_person_id clears both fields."""
    meeting_id = _create_meeting("Unassign Meeting")
    person_id = _create_person("Carol")
    task_id = _create_task(meeting_id)

    # Assign first
    resp = client.patch(f"/tasks/{task_id}", json={"owner_person_id": person_id})
    assert resp.status_code == 200
    assert resp.json()["owner_person_id"] == person_id

    # Unassign with empty string
    resp = client.patch(f"/tasks/{task_id}", json={"owner_person_id": ""})
    assert resp.status_code == 200
    data = resp.json()
    assert data["owner_person_id"] is None
    assert data["raw_owner_text"] is None


def test_assign_invalid_person_returns_404():
    """PATCH /tasks/{id} with nonexistent owner_person_id returns 404."""
    meeting_id = _create_meeting("Invalid Person Meeting")
    task_id = _create_task(meeting_id)

    resp = client.patch(f"/tasks/{task_id}", json={"owner_person_id": "nonexistent-id"})
    assert resp.status_code == 404
    assert resp.json()["detail"] == "Person not found"


def test_whitespace_only_owner_person_id_unassigns():
    """Whitespace-only owner_person_id is treated as unassign."""
    meeting_id = _create_meeting("Whitespace Meeting")
    person_id = _create_person("Dave")
    task_id = _create_task(meeting_id)

    # Assign first
    resp = client.patch(f"/tasks/{task_id}", json={"owner_person_id": person_id})
    assert resp.status_code == 200

    # Unassign with whitespace-only string
    resp = client.patch(f"/tasks/{task_id}", json={"owner_person_id": "   "})
    assert resp.status_code == 200
    data = resp.json()
    assert data["owner_person_id"] is None
    assert data["raw_owner_text"] is None


def test_update_task_status():
    """PATCH /tasks/{id} with status updates the task status."""
    meeting_id = _create_meeting("Status Meeting")
    task_id = _create_task(meeting_id)

    resp = client.patch(f"/tasks/{task_id}", json={"status": "completed"})
    assert resp.status_code == 200
    assert resp.json()["status"] == "completed"