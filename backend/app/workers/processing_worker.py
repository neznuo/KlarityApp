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
from typing import Optional

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


def _update_meeting_status(meeting_id: str, status: str, db: Optional[Session] = None) -> None:
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


def _finish_job(job: ProcessingJob, db: Session, error: Optional[str] = None) -> None:
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

            # Extract actual duration from the processed audio file (authoritative source).
            # This fills in duration_seconds even if the iOS/Mac client didn't send it.
            if not meeting.duration_seconds:
                from app.services.audio.preprocessor import find_tool_or_none
                import subprocess as _sp, json as _json
                ffprobe = find_tool_or_none("ffprobe")
                if ffprobe:
                    probe = _sp.run(
                        [ffprobe, "-v", "error", "-show_entries", "format=duration",
                         "-of", "json", str(norm_path)],
                        capture_output=True, text=True,
                    )
                    if probe.returncode == 0:
                        try:
                            dur = float(_json.loads(probe.stdout)["format"]["duration"])
                            meeting.duration_seconds = round(dur, 1)
                        except (KeyError, ValueError):
                            pass

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


def _extract_cluster_audio(
    norm_path: Path,
    segments: list,
    cluster_id: str,
) -> "Optional[Path]":
    """
    Extract and concatenate the audio windows belonging to a single speaker cluster.
    Uses FFmpeg to cut each segment by timestamp, then concatenates them.
    Returns a temp WAV path (caller is responsible for cleanup) or None on failure.
    """
    import subprocess
    import tempfile
    from app.services.audio.preprocessor import find_tool_or_none

    ffmpeg = find_tool_or_none("ffmpeg")
    if not ffmpeg or not segments:
        return None

    # Only keep segments long enough to yield a useful embedding (≥ 0.5 s)
    valid = [s for s in segments if (s.end_ms - s.start_ms) >= 500]
    if not valid:
        return None

    tmp = Path(tempfile.mkdtemp(prefix="klarity_emb_"))
    seg_paths: list[Path] = []

    for i, seg in enumerate(valid[:25]):          # cap at 25 segments for speed
        start_s  = seg.start_ms / 1000.0
        dur_s    = max((seg.end_ms - seg.start_ms) / 1000.0, 0.1)
        out_path = tmp / f"s{i}.wav"
        r = subprocess.run(
            [ffmpeg, "-y", "-i", str(norm_path),
             "-ss", f"{start_s:.3f}", "-t", f"{dur_s:.3f}",
             "-ar", "16000", "-ac", "1", "-sample_fmt", "s16", str(out_path)],
            capture_output=True,
        )
        if r.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0:
            seg_paths.append(out_path)

    if not seg_paths:
        return None

    if len(seg_paths) == 1:
        return seg_paths[0]

    # Concatenate all segments into one file
    list_file = tmp / "list.txt"
    list_file.write_text("\n".join(f"file '{p.name}'" for p in seg_paths))
    concat_out = tmp / f"cluster_{cluster_id}.wav"
    r = subprocess.run(
        [ffmpeg, "-y", "-f", "concat", "-safe", "0",
         "-i", str(list_file), "-ar", "16000", "-ac", "1", str(concat_out)],
        capture_output=True,
        cwd=str(tmp),
    )
    if r.returncode == 0 and concat_out.exists():
        return concat_out
    return seg_paths[0]   # fallback to the longest single segment


def run_speaker_matching_step(meeting_id: str, db: Optional[Session] = None) -> None:
    """
    Compute per-cluster voice embeddings and match against the known people library.
    Each cluster gets its own embedding derived from its speaker's actual audio windows,
    not the full meeting audio.
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

            # Build cluster → segments lookup
            all_segments = (
                db.query(TranscriptSegment)
                .filter(TranscriptSegment.meeting_id == meeting_id)
                .all()
            )
            segs_by_cluster: dict[str, list] = {}
            for seg in all_segments:
                segs_by_cluster.setdefault(seg.cluster_id, []).append(seg)

            # Compute one embedding per cluster from that speaker's audio windows
            cluster_embeddings: dict[str, any] = {}
            for cluster in clusters:
                try:
                    cluster_segs = segs_by_cluster.get(cluster.id, [])
                    audio_path = _extract_cluster_audio(norm_path, cluster_segs, cluster.id)
                    if audio_path is None:
                        # Fallback: embed the full audio (better than nothing)
                        audio_path = norm_path
                    embedding = embedding_svc.compute_embedding(audio_path)
                    emb_path = voice_embedding_path(f"cluster_{cluster.id}")
                    embedding_svc.save_embedding(embedding, emb_path)
                    cluster_embeddings[cluster.id] = embedding
                except Exception as exc:
                    import structlog
                    structlog.get_logger().warning(
                        "speaker_embedding_failed",
                        cluster_id=cluster.id,
                        error=str(exc),
                    )

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
                        cluster.suggested_person_id = None
                        cluster.confidence = sim
                    elif best_id and sim >= settings.speaker_suggest_threshold:
                        cluster.suggested_person_id = best_id
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

            # When called standalone (recompute), transition to transcript_ready
            if meeting.status == "matching_speakers":
                _update_meeting_status(meeting_id, "transcript_ready", db)

        except Exception as exc:
            _finish_job(job, db, error=str(exc))

    finally:
        if close:
            db.close()


def run_summarization_step(
    meeting_id: str,
    provider_name: Optional[str] = None,
    model: Optional[str] = None,
    db: Optional[Session] = None,
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

            # Also create tasks for any key_decisions that imply a follow-up action
            # (safety net for models that don't always promote decisions → action_items)
            existing_descs = {item.get("task", "").lower() for item in result.action_items}
            for decision in result.key_decisions:
                if not isinstance(decision, dict):
                    continue
                decision_text = decision.get("decision", "")
                decided_by = decision.get("decided_by") or None
                if not decision_text:
                    continue
                # Heuristic: only promote if it contains action-implying words
                action_words = ("will", "should", "need", "must", "going to", "plan",
                                "implement", "set up", "create", "build", "send",
                                "schedule", "review", "update", "follow", "prepare",
                                "ensure", "confirm", "check", "arrange", "contact")
                lower = decision_text.lower()
                if any(w in lower for w in action_words):
                    # Avoid duplicating if the LLM already added it to action_items
                    if not any(lower in existing or existing in lower for existing in existing_descs):
                        task = Task(
                            id=str(uuid.uuid4()),
                            meeting_id=meeting_id,
                            raw_owner_text=decided_by,
                            description=f"[From decision] {decision_text}",
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
