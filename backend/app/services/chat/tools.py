"""
Database-level tool functions for the AI chat agent.

Each function is designed to be called as an LLM "tool call" — it takes
simple scalar arguments and returns a JSON-serialisable dict the model can
read and reason about.

FTS searches use the meetings_fts / tasks_fts virtual tables created in
database.py::init_db().
"""

from __future__ import annotations

import json
import logging
from datetime import date, datetime, timedelta
from typing import Any

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.models.meeting import Meeting
from app.models.task import Task
from app.models.person import Person
from app.models.summary import Summary

logger = logging.getLogger(__name__)

# ─── Helpers ──────────────────────────────────────────────────────────────────

def _parse_date_range(date_range: str | None) -> tuple[datetime | None, datetime | None]:
    """Convert a human-readable date range string to (start, end) datetimes.

    Supported values (case-insensitive):
        "last 7 days", "last 30 days", "last 90 days", "this week",
        "this month", "today", or None / "all time".
    """
    if not date_range:
        return None, None

    now = datetime.utcnow()
    dr = date_range.strip().lower()

    mapping = {
        "today":        timedelta(days=1),
        "last 7 days":  timedelta(days=7),
        "last week":    timedelta(days=7),
        "last 30 days": timedelta(days=30),
        "last month":   timedelta(days=30),
        "last 90 days": timedelta(days=90),
        "last 3 months": timedelta(days=90),
        "this week":    timedelta(days=7),
        "this month":   timedelta(days=30),
    }
    for key, delta in mapping.items():
        if dr == key:
            return now - delta, now

    return None, None  # "all time" or unrecognised


def _meeting_to_dict(m: Meeting) -> dict[str, Any]:
    return {
        "meeting_id": m.id,
        "title":      m.title,
        "started_at": m.started_at.isoformat() if m.started_at else None,
        "status":     m.status,
    }


def _task_to_dict(t: Task, db: Session) -> dict[str, Any]:
    meeting = db.get(Meeting, t.meeting_id)
    return {
        "task_id":      t.id,
        "description":  t.description,
        "status":       t.status,
        "due_date":     str(t.due_date) if t.due_date else None,
        "owner":        t.raw_owner_text,
        "meeting_id":   t.meeting_id,
        "meeting_title": meeting.title if meeting else None,
        "meeting_date": meeting.started_at.isoformat() if meeting and meeting.started_at else None,
    }


# ─── Tool Implementations ─────────────────────────────────────────────────────

def search_tasks(
    db: Session,
    *,
    person_name: str | None = None,
    status: str | None = None,
    date_range: str | None = None,
) -> dict[str, Any]:
    """Return tasks matching optional filters.

    Args:
        person_name:  Partial name of the assignee (case-insensitive substring match).
        status:       "open" or "done" (None = all).
        date_range:   Human-readable range string, e.g. "last 30 days".

    Returns:
        {"count": int, "tasks": [...]}
    """
    q = db.query(Task)

    if person_name and person_name.strip():
        like = f"%{person_name.strip().lower()}%"
        q = q.filter(Task.raw_owner_text.ilike(like))

    if status and status.strip().lower() in ("open", "done"):
        q = q.filter(Task.status == status.strip().lower())

    start_dt, end_dt = _parse_date_range(date_range)
    if start_dt:
        # Filter tasks by their meeting's date by joining
        q = (
            q.join(Meeting, Task.meeting_id == Meeting.id)
             .filter(Meeting.started_at >= start_dt)
        )
        if end_dt:
            q = q.filter(Meeting.started_at <= end_dt)

    tasks = q.order_by(Task.created_at.desc()).limit(50).all()
    return {
        "count": len(tasks),
        "tasks": [_task_to_dict(t, db) for t in tasks],
    }


def search_meetings(
    db: Session,
    *,
    topic_keyword: str,
    date_range: str | None = None,
) -> dict[str, Any]:
    """Full-text search over meeting titles and summaries.

    Args:
        topic_keyword:  Search term (e.g. "website migration").
        date_range:     Human-readable range string.

    Returns:
        {"count": int, "meetings": [...]}
    """
    start_dt, end_dt = _parse_date_range(date_range)

    try:
        # Try FTS5 first
        fts_rows = db.execute(
            text(
                "SELECT meeting_id FROM meetings_fts WHERE meetings_fts MATCH :q ORDER BY rank LIMIT 20"
            ),
            {"q": topic_keyword},
        ).fetchall()
        meeting_ids = [r[0] for r in fts_rows]
    except Exception:
        logger.warning("FTS search failed, falling back to LIKE", exc_info=True)
        like = f"%{topic_keyword}%"
        rows = db.execute(
            text("SELECT id FROM meetings WHERE title LIKE :q LIMIT 20"),
            {"q": like},
        ).fetchall()
        meeting_ids = [r[0] for r in rows]

    meetings = []
    for mid in meeting_ids:
        m = db.get(Meeting, mid)
        if m is None:
            continue
        if start_dt and (m.started_at is None or m.started_at < start_dt):
            continue
        if end_dt and m.started_at and m.started_at > end_dt:
            continue
        meetings.append(_meeting_to_dict(m))

    return {"count": len(meetings), "meetings": meetings}


def get_meeting_summary(db: Session, *, meeting_id: str) -> dict[str, Any]:
    """Fetch the full details (summary + decisions + tasks) for a single meeting.

    Args:
        meeting_id:  The UUID of the meeting.

    Returns:
        Rich dict with title, decisions, tasks, action_items, etc.
    """
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        return {"error": f"Meeting {meeting_id!r} not found."}

    summary_row = (
        db.query(Summary)
        .filter(Summary.meeting_id == meeting_id)
        .order_by(Summary.created_at.desc())
        .first()
    )

    parsed_json: dict = {}
    if summary_row and summary_row.summary_json:
        try:
            parsed_json = json.loads(summary_row.summary_json)
        except json.JSONDecodeError:
            pass

    tasks = db.query(Task).filter(Task.meeting_id == meeting_id).all()

    return {
        "meeting_id":      meeting.id,
        "title":           meeting.title,
        "date":            meeting.started_at.isoformat() if meeting.started_at else None,
        "meeting_summary": parsed_json.get("meeting_summary", ""),
        "key_decisions":   parsed_json.get("key_decisions", []),
        "action_items":    parsed_json.get("action_items", []),
        "open_questions":  parsed_json.get("open_questions", []),
        "risks":           parsed_json.get("risks_and_blockers", []),
        "key_insights":    parsed_json.get("key_insights", []),
        "topics_discussed": parsed_json.get("topics_discussed", []),
        "tasks_in_db":     [_task_to_dict(t, db) for t in tasks],
    }


def list_people(db: Session) -> dict[str, Any]:
    """List all known people/contacts in the database.

    Returns:
        {"count": int, "people": [{"name": ..., "id": ..., "meeting_count": ...}]}
    """
    people = db.query(Person).order_by(Person.display_name).all()
    return {
        "count": len(people),
        "people": [
            {"id": p.id, "name": p.display_name, "meeting_count": p.meeting_count}
            for p in people
        ],
    }


# ─── Tool Schema (OpenAI / Anthropic function-calling format) ─────────────────

TOOL_DEFINITIONS: list[dict] = [
    {
        "name": "search_tasks",
        "description": (
            "Search for action items / tasks across all meetings. "
            "Can filter by the person assigned, task status, and date range."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "person_name": {
                    "type": "string",
                    "description": "Partial name of the task owner / assignee (case-insensitive).",
                },
                "status": {
                    "type": "string",
                    "enum": ["open", "done"],
                    "description": "Task status filter.",
                },
                "date_range": {
                    "type": "string",
                    "description": (
                        "Restrict to meetings in this period. Examples: "
                        "'last 7 days', 'last 30 days', 'last 90 days', 'today', 'all time'."
                    ),
                },
            },
        },
    },
    {
        "name": "search_meetings",
        "description": (
            "Full-text search over meeting titles and AI-generated summaries. "
            "Use this to find meetings that discussed a specific topic."
        ),
        "parameters": {
            "type": "object",
            "required": ["topic_keyword"],
            "properties": {
                "topic_keyword": {
                    "type": "string",
                    "description": "Keyword or phrase to search for (e.g. 'website migration', 'Q3 budget').",
                },
                "date_range": {
                    "type": "string",
                    "description": "Optional date range (same values as search_tasks).",
                },
            },
        },
    },
    {
        "name": "get_meeting_summary",
        "description": (
            "Retrieve full details for a specific meeting: summary, key decisions, "
            "action items, open questions, and tasks."
        ),
        "parameters": {
            "type": "object",
            "required": ["meeting_id"],
            "properties": {
                "meeting_id": {
                    "type": "string",
                    "description": "The UUID of the meeting to retrieve.",
                },
            },
        },
    },
    {
        "name": "list_people",
        "description": "List all contacts/people known to Klarity (from past meeting participants).",
        "parameters": {
            "type": "object",
            "properties": {},
        },
    },
]

# Mapping from tool name to implementation
TOOL_REGISTRY = {
    "search_tasks":        search_tasks,
    "search_meetings":     search_meetings,
    "get_meeting_summary": get_meeting_summary,
    "list_people":         list_people,
}
