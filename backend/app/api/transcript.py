"""Transcript retrieval and speaker assignment endpoints."""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.database import get_db
from app.models.meeting import Meeting
from app.models.person import Person
from app.models.speaker import SpeakerCluster
from app.models.transcript import TranscriptSegment
from app.schemas import (
    AssignSpeakerRequest,
    ConfirmSuggestionRequest,
    MergeSpeakersRequest,
    SpeakerClusterOut,
    TranscriptSegmentOut,
)

router = APIRouter(prefix="/meetings", tags=["transcript"])


@router.get("/{meeting_id}/transcript", response_model=list[TranscriptSegmentOut])
def get_transcript(meeting_id: str, db: Session = Depends(get_db)):
    """Return all transcript segments enriched with resolved speaker labels."""
    meeting = db.get(Meeting, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")

    segments = (
        db.query(TranscriptSegment)
        .filter(TranscriptSegment.meeting_id == meeting_id)
        .order_by(TranscriptSegment.start_ms)
        .all()
    )

    # Build cluster→speaker label map
    clusters = (
        db.query(SpeakerCluster)
        .filter(SpeakerCluster.meeting_id == meeting_id)
        .all()
    )
    cluster_labels: dict[str, str] = {}
    for c in clusters:
        if c.assigned_person_id:
            person = db.get(Person, c.assigned_person_id)
            cluster_labels[c.id] = person.display_name if person else c.temp_label
        else:
            cluster_labels[c.id] = c.temp_label

    result = []
    for seg in segments:
        out = TranscriptSegmentOut.model_validate(seg)
        out.speaker_label = cluster_labels.get(seg.cluster_id or "", None)
        result.append(out)
    return result


@router.post("/{meeting_id}/assign-speaker")
def assign_speaker(
    meeting_id: str, body: AssignSpeakerRequest, db: Session = Depends(get_db)
):
    """Assign a known person (or create a new one) to a speaker cluster."""
    cluster = db.get(SpeakerCluster, body.cluster_id)
    if not cluster or cluster.meeting_id != meeting_id:
        raise HTTPException(status_code=404, detail="Speaker cluster not found")

    if body.person_id:
        person = db.get(Person, body.person_id)
        if not person:
            raise HTTPException(status_code=404, detail="Person not found")
        cluster.assigned_person_id = person.id
    elif body.new_person_name:
        person = Person(display_name=body.new_person_name)
        db.add(person)
        db.flush()
        cluster.assigned_person_id = person.id
    else:
        raise HTTPException(status_code=400, detail="Provide person_id or new_person_name")

    # ── Save the cluster's voice embedding as this person's voice model ──────
    # This is what makes speaker recognition work in future meetings.
    from app.services.storage.file_layout import voice_embedding_path
    import shutil
    cluster_emb = voice_embedding_path(f"cluster_{cluster.id}")
    person_emb = voice_embedding_path(person.id)

    if cluster_emb.exists():
        try:
            shutil.copy2(str(cluster_emb), str(person_emb))
        except Exception:
            pass  # Non-fatal — recognition just won't work for this person yet
    else:
        # Cluster embedding doesn't exist (e.g., embedding step failed during
        # processing). Compute it now from the cluster's audio segments.
        from app.workers.processing_worker import _extract_cluster_audio
        from app.services.embeddings.speaker_embedding import SpeakerEmbeddingService
        meeting_obj = db.get(Meeting, meeting_id)
        if meeting_obj and meeting_obj.normalized_audio_path:
            norm_path = Path(meeting_obj.normalized_audio_path)
            if norm_path.exists():
                segments = (
                    db.query(TranscriptSegment)
                    .filter(
                        TranscriptSegment.cluster_id == cluster.id,
                        TranscriptSegment.meeting_id == meeting_id,
                    )
                    .all()
                )
                audio_path = _extract_cluster_audio(norm_path, segments, cluster.id)
                if audio_path is not None:
                    try:
                        svc = SpeakerEmbeddingService()
                        embedding = svc.compute_embedding(audio_path)
                        svc.save_embedding(embedding, cluster_emb)
                        shutil.copy2(str(cluster_emb), str(person_emb))
                    except Exception:
                        pass

    # ── Update person stats ───────────────────────────────────────────────────
    from sqlalchemy import func as sqlfunc
    meeting = db.get(Meeting, meeting_id)
    if meeting and meeting.started_at:
        person.last_seen_at = meeting.started_at
    # Recount meetings where this person appears
    person.meeting_count = (
        db.query(sqlfunc.count(SpeakerCluster.meeting_id.distinct()))
        .filter(SpeakerCluster.assigned_person_id == person.id)
        .scalar()
        or 0
    )

    db.commit()
    return {"message": "Speaker assigned", "cluster_id": cluster.id}


@router.post("/{meeting_id}/merge-speakers")
def merge_speakers(
    meeting_id: str, body: MergeSpeakersRequest, db: Session = Depends(get_db)
):
    """
    Merge source clusters into a target cluster.
    All transcript segments from source clusters are re-pointed to the target.
    """
    target = db.get(SpeakerCluster, body.target_cluster_id)
    if not target or target.meeting_id != meeting_id:
        raise HTTPException(status_code=404, detail="Target cluster not found")

    # Resolve target person
    if body.target_person_id:
        target.assigned_person_id = body.target_person_id
    elif body.new_person_name:
        person = Person(display_name=body.new_person_name)
        db.add(person)
        db.flush()
        target.assigned_person_id = person.id

    for src_id in body.source_cluster_ids:
        source = db.get(SpeakerCluster, src_id)
        if not source or source.meeting_id != meeting_id:
            continue
        # Re-assign all segments from this source to the target cluster
        segs = (
            db.query(TranscriptSegment)
            .filter(TranscriptSegment.cluster_id == src_id)
            .all()
        )
        for seg in segs:
            seg.cluster_id = target.id
        target.segment_count += len(segs)
        if source.duration_seconds:
            target.duration_seconds = (target.duration_seconds or 0.0) + source.duration_seconds
        db.delete(source)

    db.commit()
    return {"message": "Speakers merged", "target_cluster_id": target.id}


@router.get("/{meeting_id}/speakers", response_model=list[SpeakerClusterOut])
def get_speakers(meeting_id: str, db: Session = Depends(get_db)):
    """Return all speaker clusters for a meeting (detected-people panel)."""
    clusters = (
        db.query(SpeakerCluster)
        .filter(SpeakerCluster.meeting_id == meeting_id)
        .all()
    )
    # Resolve suggested person names
    suggestion_ids = {c.suggested_person_id for c in clusters if c.suggested_person_id}
    suggested_people = {}
    if suggestion_ids:
        for p in db.query(Person).filter(Person.id.in_(suggestion_ids)).all():
            suggested_people[p.id] = p.display_name

    result = []
    for c in clusters:
        out = SpeakerClusterOut.model_validate(c)
        if c.suggested_person_id and c.suggested_person_id in suggested_people:
            out.suggested_person_name = suggested_people[c.suggested_person_id]
        result.append(out)
    return result


@router.post("/{meeting_id}/confirm-suggestion")
def confirm_suggestion(
    meeting_id: str, body: ConfirmSuggestionRequest, db: Session = Depends(get_db)
):
    """One-click confirm: accept the AI-suggested person for a speaker cluster."""
    cluster = db.get(SpeakerCluster, body.cluster_id)
    if not cluster or cluster.meeting_id != meeting_id:
        raise HTTPException(status_code=404, detail="Speaker cluster not found")

    if not cluster.suggested_person_id:
        raise HTTPException(status_code=400, detail="No suggestion for this cluster")

    person = db.get(Person, cluster.suggested_person_id)
    if not person:
        raise HTTPException(status_code=404, detail="Suggested person not found")

    # Accept the suggestion
    cluster.assigned_person_id = cluster.suggested_person_id
    cluster.suggested_person_id = None

    # Copy cluster voice embedding as this person's voice model
    from app.services.storage.file_layout import voice_embedding_path
    import shutil
    cluster_emb = voice_embedding_path(f"cluster_{cluster.id}")
    if cluster_emb.exists():
        person_emb = voice_embedding_path(person.id)
        try:
            shutil.copy2(str(cluster_emb), str(person_emb))
        except Exception:
            pass

    # Update person stats
    from sqlalchemy import func as sqlfunc
    meeting = db.get(Meeting, meeting_id)
    if meeting and meeting.started_at:
        person.last_seen_at = meeting.started_at
    person.meeting_count = (
        db.query(sqlfunc.count(SpeakerCluster.meeting_id.distinct()))
        .filter(SpeakerCluster.assigned_person_id == person.id)
        .scalar()
        or 0
    )

    db.commit()
    return {"message": "Suggestion confirmed", "cluster_id": cluster.id}


@router.post("/{meeting_id}/dismiss-suggestion")
def dismiss_suggestion(
    meeting_id: str, body: ConfirmSuggestionRequest, db: Session = Depends(get_db)
):
    """Dismiss the AI-suggested person for a speaker cluster."""
    cluster = db.get(SpeakerCluster, body.cluster_id)
    if not cluster or cluster.meeting_id != meeting_id:
        raise HTTPException(status_code=404, detail="Speaker cluster not found")

    cluster.suggested_person_id = None
    db.commit()
    return {"message": "Suggestion dismissed", "cluster_id": cluster.id}
