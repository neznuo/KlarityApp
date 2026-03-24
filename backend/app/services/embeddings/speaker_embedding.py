"""
Speaker embedding service using WeSpeaker ECAPA-TDNN512-LM (ONNX).

Generates 192-dim d-vector embeddings from 16kHz mono WAV files and compares
them using cosine similarity against the known people library.

Replaces the previous resemblyzer-based implementation with a fully
torch-free pipeline: kaldi-native-fbank preprocessing + onnxruntime inference.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from app.core.config import settings
from app.services.embeddings.audio_utils import (
    EMBEDDING_DIM,  # noqa: F401 — exported for callers that need it
    MODEL_NAME,
    compute_embedding_from_fbank,
    compute_fbank,
)

# Path to the bundled ONNX model, relative to the backend package root.
# At runtime inside the .app bundle the CWD is set to Resources/backend,
# so this resolves correctly both in dev and in the packaged app.
_MODEL_PATH = Path(__file__).parent.parent.parent.parent / "models" / "speaker_encoder.onnx"


def _cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Compute cosine similarity between two 1-D vectors."""
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(a, b) / (norm_a * norm_b))


class SpeakerEmbeddingService:
    """
    Creates and compares voice embeddings using WeSpeaker ECAPA-TDNN512-LM (ONNX).
    Embeddings are saved as .npy files in the voices directory.

    The ONNX session is lazy-loaded on first use and reused across calls.
    All methods maintain the same public API as the previous resemblyzer-based
    implementation so processing_worker.py requires no changes.
    """

    def __init__(self) -> None:
        self._session = None  # lazy-loaded onnxruntime.InferenceSession

    def _get_session(self):
        if self._session is None:
            try:
                import onnxruntime as ort
            except ImportError as e:
                raise RuntimeError(
                    "onnxruntime is not installed. Run: pip install onnxruntime"
                ) from e

            if not _MODEL_PATH.exists():
                raise RuntimeError(
                    f"Speaker encoder model not found at {_MODEL_PATH}. "
                    "Re-run the Xcode build phase to bundle the model."
                )

            self._session = ort.InferenceSession(
                str(_MODEL_PATH),
                providers=["CPUExecutionProvider"],
            )
        return self._session

    def compute_embedding(self, audio_path: Path) -> np.ndarray:
        """
        Compute a speaker embedding from a WAV file.
        Expects 16kHz mono WAV (produced by the FFmpeg preprocessor).

        Returns:
            L2-normalized np.ndarray of shape [192].
        """
        feats = compute_fbank(audio_path)
        return compute_embedding_from_fbank(feats, self._get_session())

    def save_embedding(self, embedding: np.ndarray, save_path: Path) -> Path:
        """Persist an embedding vector to a .npy file."""
        save_path.parent.mkdir(parents=True, exist_ok=True)
        np.save(str(save_path), embedding)
        return save_path

    def load_embedding(self, path: Path) -> np.ndarray:
        """Load a persisted embedding from a .npy file."""
        return np.load(str(path))

    def find_best_match(
        self,
        query_embedding: np.ndarray,
        candidate_embeddings: dict[str, np.ndarray],
    ) -> tuple[str | None, float]:
        """
        Find the best matching person among candidate embeddings.
        Returns (person_id_or_None, similarity_score).
        """
        best_id: str | None = None
        best_sim = 0.0
        for person_id, emb in candidate_embeddings.items():
            sim = _cosine_similarity(query_embedding, emb)
            if sim > best_sim:
                best_sim = sim
                best_id = person_id
        return best_id, best_sim

    def check_duplicates(
        self,
        cluster_embeddings: dict[str, np.ndarray],
        threshold: float | None = None,
    ) -> list[tuple[str, str, float]]:
        """
        Look for potential duplicate speaker clusters within a meeting.
        Returns list of (cluster_id_a, cluster_id_b, similarity) tuples.
        """
        if threshold is None:
            threshold = settings.speaker_duplicate_threshold

        ids = list(cluster_embeddings.keys())
        duplicates = []
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                sim = _cosine_similarity(
                    cluster_embeddings[ids[i]], cluster_embeddings[ids[j]]
                )
                if sim >= threshold:
                    duplicates.append((ids[i], ids[j], sim))
        return duplicates
