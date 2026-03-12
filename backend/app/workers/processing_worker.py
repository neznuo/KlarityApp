"""
Processing pipeline worker.

Orchestrates the full meeting processing workflow:
  1. preprocess audio (FFmpeg)
  2. transcribe (ElevenLabs)
  3. generate speaker embeddings (Resemblyzer)
  4. match clusters against known people

Summary generation is intentionally NOT called here.
It runs only when triggered manually through the API.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy.orm import Session

from app.core.config import settings
from app.db.database import SessionLocal
from app.models.job import ProcessingJob
from app.models.meeting import Meeting
from app.models.person import PersonEmbedding
from app.models.speaker import SpeakerCluster
from app.models.summary import Summary
from app.models.task import Task
from app.models.transcript import TranscriptSegment
from app.services.audio.preprocessor import AudioPreprocessor
from app.services.embeddings.speaker_embedding import SpeakerEmbeddingService
from app.services.storage.file_layout import (
    normalized_audio_path,
    summary_json_path,
    summary_md_path,
    tasks_json_path,
    transcript_json_path,
    transcript_raw_json_path,
    voice_embedding_path,
)
from app.services.transcription.base import get_provider as get_transcription_provider


def _get_db() -> Session:
    return SessionLocal()


def _update_meeting_status(meeting_id: str, status: str, db: Session | None = None) -> None:
    close = db is None
    if db is None:
        db = _get_db()
    try:
        meeting = db.get(Meeting, meeting_id)
        if meeting:
            meeting.status = status
            meeting.updated_at = datetime.now(timezone.utc)
            db.commit()
    finally:
        if close:
            db.close()


def _record_job(meeting_id: str, job_type: str, db: Session) -> ProcessingJob:
    job = ProcessingJob(
        id=str(uuid.uuid4()),
        meeting_id=meeting_id,
        job_type=job_type,
        status="running",
        started_at=datetime.now(timezone.utc),
    )
    db.add(job)
    db.commit()
    return job


def _finish_job(job: ProcessingJob, db: Session, error: str | None = None) -> None:
    job.status = "failed" if error else "done"
    job.error_message = error
    job.finished_at = datetime.now(timezone.utc)
    db.commit()


def run_processing_pipeline(meeting_id: str) -> None:
    """Full pipeline: preprocess → transcribe → embed → match."""
    db = _get_db()
    try:
        meeting = db.get(Meeting, meeting_id)
        if not meeting or not meeting.audio_file_path:
            return

        audio_src = Path(meeting.audio_file_path)

        # ── Step 1: Preprocess ─────────────────────────────────────────────
        _update_meeting_status(meeting_id, "preprocessing", db)
        job = _record_job(meeting_id, "preprocess", db)
        try:
            preprocessor = AudioPreprocessor()
            norm_path = normalized_audio_path(meeting_id)
            preprocessor.preprocess(audio_src, norm_path)
            meeting.normalized_audio_path = str(norm_path)
            db.commit()
            _finish_job(job, db)
        except Exception as exc:
            _finish_job(job, db, error=str(exc))
            _update_meeting_status(meeting_id, "failed", db)
            return

        # ── Step 2: Transcribe ─────────────────────────────────────────────
        _update_meeting_status(meeting_id, "transcribing", db)
        job = _record_job(meeting_id, "transcribe", db)
        try:
            provider = get_transcription_provider(settings.default_transcription_provider)
            result = provider.transcribe(norm_path)

            # Save raw provider JSON
            raw_json_path = transcript_raw_json_path(meeting_id)
            raw_json_path.write_text(json.dumps(result.raw_response, indent=2))

            # Persist speaker clusters + segments
            clusters: dict[str, SpeakerCluster] = {}
            for seg in result.segments:
                speaker_id = seg.speaker_id
                if speaker_id not in clusters:
                    cluster = SpeakerCluster(
                        id=str(uuid.uuid4()),
                        meeting_id=meeting_id,
                        temp_label=speaker_id,
                        segment_count=0,
                        duration_seconds=0.0,
                    )
                    db.add(cluster)
                    db.flush()
                    clusters[speaker_id] = cluster

                cluster = clusters[speaker_id]
                cluster.segment_count += 1
                duration_s = (seg.end_ms - seg.start_ms) / 1000.0
                cluster.duration_seconds = (cluster.duration_seconds or 0.0) + duration_s

                segment = TranscriptSegment(
                    id=str(uuid.uuid4()),
                    meeting_id=meeting_id,
                    cluster_id=cluster.id,
                    start_ms=seg.start_ms,
                    end_ms=seg.end_ms,
                    text=seg.text,
                    confidence=seg.confidence,
                )
                db.add(segment)

            # Save structured transcript JSON
            t_json_path = transcript_json_path(meeting_id)
            transcript_data = [
                {
                    "speaker": s.speaker_id,
                    "start_ms": s.start_ms,
                    "end_ms": s.end_ms,
                    "text": s.text,
                }
                for s in result.segments
            ]
            t_json_path.write_text(json.dumps(transcript_data, indent=2))
            meeting.transcript_json_path = str(t_json_path)
            db.commit()
            _finish_job(job, db)
        except Exception as exc:
            _finish_job(job, db, error=str(exc))
            _update_meeting_status(meeting_id, "failed", db)
            return

        # ── Step 3: Embed + match ──────────────────────────────────────────
        run_speaker_matching_step(meeting_id, db=db)

        _update_meeting_status(meeting_id, "transcript_ready", db)

    finally:
        db.close()


def run_speaker_matching_step(meeting_id: str, db: Session | None = None) -> None:
    """
    Compute embeddings for each speaker cluster and compare to known people.
    Sets suggested assignments and duplicate hints on clusters.
    """
    close = db is None
    if db is None:
        db = _get_db()

    try:
        _update_meeting_status(meeting_id, "matching_speakers", db)
        job = _record_job(meeting_id, "embed", db)

        try:
            meeting = db.get(Meeting, meeting_id)
            if not meeting or not meeting.normalized_audio_path:
                _finish_job(job, db, error="No normalized audio")
                return

            norm_path = Path(meeting.normalized_audio_path)
            embedding_svc = SpeakerEmbeddingService()

            clusters = (
                db.query(SpeakerCluster)
                .filter(SpeakerCluster.meeting_id == meeting_id)
                .all()
            )

            if not clusters:
                _finish_job(job, db)
                return

            # For a real implementation, extract per-cluster audio segments.
            # Here we compute one embedding of the full audio per cluster as a placeholder.
            # TODO: extract actual cluster-specific audio windows using start/end timestamps.
            cluster_embeddings: dict[str, any] = {}
            for cluster in clusters:
                try:
                    embedding = embedding_svc.compute_embedding(norm_path)
                    emb_path = voice_embedding_path(f"cluster_{cluster.id}")
                    embedding_svc.save_embedding(embedding, emb_path)
                    cluster_embeddings[cluster.id] = embedding
                except Exception:
                    pass  # Non-fatal — skip embedding for this cluster

            # Load known person embeddings
            from app.models.person import Person
            people = db.query(Person).all()
            person_embeddings: dict[str, any] = {}
            for person in people:
                emb_path = voice_embedding_path(person.id)
                if emb_path.exists():
                    try:
                        person_embeddings[person.id] = embedding_svc.load_embedding(emb_path)
                    except Exception:
                        pass

            # Match clusters against known people
            if person_embeddings:
                for cluster in clusters:
                    if cluster.id not in cluster_embeddings:
                        continue
                    best_id, sim = embedding_svc.find_best_match(
                        cluster_embeddings[cluster.id], person_embeddings
                    )
                    if best_id and sim >= settings.speaker_auto_assign_threshold:
                        cluster.assigned_person_id = best_id
                        cluster.confidence = sim
                    elif best_id and sim >= settings.speaker_suggest_threshold:
                        # Just store the suggestion in confidence; frontend shows it
                        cluster.confidence = sim

            # Detect duplicate clusters
            if len(cluster_embeddings) > 1:
                dupes = embedding_svc.check_duplicates(cluster_embeddings)
                for id_a, id_b, sim in dupes:
                    c = db.get(SpeakerCluster, id_b)
                    if c:
                        c.duplicate_group_hint = id_a

            db.commit()
            _finish_job(job, db)

        except Exception as exc:
            _finish_job(job, db, error=str(exc))

    finally:
        if close:
            db.close()


def run_summarization_step(
    meeting_id: str,
    provider_name: str | None = None,
    model: str | None = None,
    db: Session | None = None,
) -> None:
    """
    Generate meeting summary using the configured LLM provider.
    ONLY called when the user manually clicks Generate Summary & Tasks.
    """
    close = db is None
    if db is None:
        db = _get_db()

    try:
        p_name = provider_name or settings.default_llm_provider
        m_name = model or settings.default_llm_model
        _update_meeting_status(meeting_id, "summarizing", db)
        job = _record_job(meeting_id, "summarize", db)

        try:
            meeting = db.get(Meeting, meeting_id)
            if not meeting:
                _finish_job(job, db, error="Meeting not found")
                return

            # Build transcript text with resolved speaker names
            from app.models.person import Person
            from app.models.speaker import SpeakerCluster

            segments = (
                db.query(TranscriptSegment)
                .filter(TranscriptSegment.meeting_id == meeting_id)
                .order_by(TranscriptSegment.start_ms)
                .all()
            )
            clusters = {
                c.id: c
                for c in db.query(SpeakerCluster)
                .filter(SpeakerCluster.meeting_id == meeting_id)
                .all()
            }

            lines = []
            for seg in segments:
                cluster = clusters.get(seg.cluster_id or "")
                if cluster and cluster.assigned_person_id:
                    person = db.get(Person, cluster.assigned_person_id)
                    label = person.display_name if person else cluster.temp_label
                else:
                    label = cluster.temp_label if cluster else "Unknown"
                start_s = seg.start_ms / 1000
                m, s = divmod(int(start_s), 60)
                h, m = divmod(m, 60)
                ts = f"{h:02d}:{m:02d}:{s:02d}"
                lines.append(f"[{ts}] {label}: {seg.text}")

            transcript_text = "\n".join(lines)

            from app.services.summarization.base import get_provider
            provider = get_provider(p_name)
            result = provider.summarize(transcript_text, model=m_name)

            # Save artifacts
            s_json_path = summary_json_path(meeting_id)
            s_json_path.write_text(json.dumps(result.raw_json, indent=2))
            s_md_path = summary_md_path(meeting_id)
            s_md_path.write_text(result.markdown)

            # Save tasks JSON
            t_path = tasks_json_path(meeting_id)
            t_path.write_text(json.dumps(result.action_items, indent=2))

            # Persist to database
            summary = Summary(
                id=str(uuid.uuid4()),
                meeting_id=meeting_id,
                provider=p_name,
                model=m_name,
                summary_markdown=result.markdown,
                summary_json=json.dumps(result.raw_json),
            )
            db.add(summary)

            for item in result.action_items:
                task = Task(
                    id=str(uuid.uuid4()),
                    meeting_id=meeting_id,
                    raw_owner_text=item.get("owner") or None,
                    description=item.get("task", ""),
                )
                db.add(task)

            meeting.summary_json_path = str(s_json_path)
            db.commit()

            _finish_job(job, db)
            _update_meeting_status(meeting_id, "complete", db)

        except Exception as exc:
            _finish_job(job, db, error=str(exc))
            _update_meeting_status(meeting_id, "failed", db)

    finally:
        if close:
            db.close()
