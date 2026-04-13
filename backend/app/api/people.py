"""People CRUD endpoints."""

from __future__ import annotations

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.database import get_db
from app.models.person import Person
from app.schemas import PersonCreate, PersonOut, PersonUpdate
from app.services.storage.file_layout import voice_embedding_path

router = APIRouter(prefix="/people", tags=["people"])


def _with_voice_status(person: Person) -> PersonOut:
    out = PersonOut.model_validate(person)
    out.has_voice_embedding = voice_embedding_path(person.id).exists()
    return out


@router.get("", response_model=list[PersonOut])
def list_people(db: Session = Depends(get_db)):
    people = db.query(Person).order_by(Person.display_name).all()
    return [_with_voice_status(p) for p in people]


@router.post("", response_model=PersonOut, status_code=201)
def create_person(body: PersonCreate, db: Session = Depends(get_db)):
    person = Person(**body.model_dump())
    db.add(person)
    db.commit()
    db.refresh(person)
    return _with_voice_status(person)


@router.patch("/{person_id}", response_model=PersonOut)
def update_person(person_id: str, body: PersonUpdate, db: Session = Depends(get_db)):
    person = db.get(Person, person_id)
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")
    for key, value in body.model_dump(exclude_none=True).items():
        setattr(person, key, value)
    db.commit()
    db.refresh(person)
    return _with_voice_status(person)


@router.delete("/{person_id}", status_code=204)
def delete_person(person_id: str, db: Session = Depends(get_db)):
    person = db.get(Person, person_id)
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")
    db.delete(person)
    db.commit()


@router.get("/{person_id}/meetings")
def get_person_meetings(person_id: str, db: Session = Depends(get_db)):
    """All meetings where this person was identified as a speaker."""
    from app.models.meeting import Meeting
    from app.models.speaker import SpeakerCluster
    from app.schemas import MeetingListOut

    person = db.get(Person, person_id)
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")

    rows = (
        db.query(SpeakerCluster.meeting_id.distinct())
        .filter(SpeakerCluster.assigned_person_id == person_id)
        .all()
    )
    ids = [r[0] for r in rows]
    if not ids:
        return []

    meetings = (
        db.query(Meeting)
        .filter(Meeting.id.in_(ids))
        .order_by(Meeting.created_at.desc())
        .all()
    )
    return [MeetingListOut.model_validate(m) for m in meetings]


@router.post("/{person_id}/recompute-embedding")
def recompute_person_embedding(
    person_id: str,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """
    Re-derive this person's voice model from all meetings they've been identified in.
    Useful for building a voice profile retroactively from past recordings.
    """
    person = db.get(Person, person_id)
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")

    background_tasks.add_task(_rebuild_person_embedding, person_id)
    return {"message": "Voice model rebuild started", "person_id": person_id}


# ── Background task ──────────────────────────────────────────────────────────

def _rebuild_person_embedding(person_id: str) -> None:
    """
    Collects audio from all meetings where this person was identified,
    concatenates it, and computes a fresh voice embedding.
    """
    import shutil
    import subprocess
    import tempfile
    from pathlib import Path

    from app.db.database import SessionLocal
    from app.models.meeting import Meeting
    from app.models.speaker import SpeakerCluster
    from app.models.transcript import TranscriptSegment
    from app.services.audio.preprocessor import find_tool_or_none
    from app.services.embeddings.speaker_embedding import SpeakerEmbeddingService

    db = SessionLocal()
    try:
        clusters = (
            db.query(SpeakerCluster)
            .filter(SpeakerCluster.assigned_person_id == person_id)
            .all()
        )
        if not clusters:
            return

        ffmpeg = find_tool_or_none("ffmpeg")
        if not ffmpeg:
            return

        tmp = Path(tempfile.mkdtemp(prefix="klarity_rebuild_"))
        seg_files: list[Path] = []

        for cluster in clusters:
            meeting = db.get(Meeting, cluster.meeting_id)
            if not meeting or not meeting.normalized_audio_path:
                continue
            norm_path = Path(meeting.normalized_audio_path)
            if not norm_path.exists():
                continue

            segments = (
                db.query(TranscriptSegment)
                .filter(
                    TranscriptSegment.cluster_id == cluster.id,
                    TranscriptSegment.meeting_id == cluster.meeting_id,
                )
                .all()
            )
            for i, seg in enumerate(segments[:10]):
                if (seg.end_ms - seg.start_ms) < 500:
                    continue
                start_s = seg.start_ms / 1000.0
                dur_s = (seg.end_ms - seg.start_ms) / 1000.0
                out = tmp / f"{cluster.id}_{i}.wav"
                r = subprocess.run(
                    [ffmpeg, "-y", "-i", str(norm_path),
                     "-ss", f"{start_s:.3f}", "-t", f"{dur_s:.3f}",
                     "-ar", "16000", "-ac", "1", "-sample_fmt", "s16", str(out)],
                    capture_output=True,
                )
                if r.returncode == 0 and out.exists() and out.stat().st_size > 0:
                    seg_files.append(out)

        if not seg_files:
            shutil.rmtree(tmp, ignore_errors=True)
            return

        # Concatenate all collected segments
        list_file = tmp / "list.txt"
        list_file.write_text("\n".join(f"file '{p.name}'" for p in seg_files))
        combined = tmp / "combined.wav"
        r = subprocess.run(
            [ffmpeg, "-y", "-f", "concat", "-safe", "0",
             "-i", str(list_file), "-ar", "16000", "-ac", "1", str(combined)],
            capture_output=True, cwd=str(tmp),
        )
        audio_to_embed = combined if (r.returncode == 0 and combined.exists()) else seg_files[0]

        svc = SpeakerEmbeddingService()
        embedding = svc.compute_embedding(audio_to_embed)
        svc.save_embedding(embedding, voice_embedding_path(person_id))

        shutil.rmtree(tmp, ignore_errors=True)
    except Exception as exc:
        import structlog
        structlog.get_logger().warning(
            "rebuild_embedding_failed",
            person_id=person_id,
            error=str(exc),
        )
    finally:
        db.close()
