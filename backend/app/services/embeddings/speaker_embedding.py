"""
Speaker embedding service using Resemblyzer.

Generates d-vector embeddings from audio clips and compares them
using cosine similarity against the known people library.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from app.core.config import settings


def _cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Compute cosine similarity between two 1-D vectors."""
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(a, b) / (norm_a * norm_b))


class SpeakerEmbeddingService:
    """
    Creates and compares voice embeddings using Resemblyzer.
    Embeddings are saved as .npy files in the voices directory.
    """

    def __init__(self):
        self._encoder = None  # Lazy-loaded — Resemblyzer is heavy to import

    def _get_encoder(self):
        if self._encoder is None:
            try:
                from resemblyzer import VoiceEncoder
                self._encoder = VoiceEncoder()
            except ImportError as e:
                raise RuntimeError(
                    "resemblyzer is not installed. Run: pip install resemblyzer"
                ) from e
        return self._encoder

    def compute_embedding(self, audio_path: Path) -> np.ndarray:
        """
        Compute a speaker d-vector embedding from a WAV file.
        Expects 16kHz mono WAV (preprocessed audio).
        """
        from resemblyzer import preprocess_wav

        encoder = self._get_encoder()
        wav = preprocess_wav(audio_path)
        embedding = encoder.embed_utterance(wav)
        return embedding

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
