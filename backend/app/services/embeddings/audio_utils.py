"""
Audio preprocessing utilities for ONNX-based speaker embedding.

Computes Kaldi-compatible log-mel filterbank (fbank) features from a WAV file,
matching the preprocessing expected by WeSpeaker ECAPA-TDNN512-LM.

Parameters match the WeSpeaker training config:
  - 16 kHz mono input (guaranteed by FFmpeg preprocessor)
  - 80 mel bins, 25 ms frame, 10 ms hop, Hamming window
  - CMN: per-utterance mean subtraction (no variance normalization)
  - Dither: 0.0 at inference
"""

from __future__ import annotations

from pathlib import Path

import kaldi_native_fbank as knf
import numpy as np
import soundfile as sf

# Embedding model metadata — must match the loaded ONNX model
# Note: "512" in ECAPA-TDNN512 refers to TDNN channel width, not output dim
EMBEDDING_DIM = 192
MODEL_NAME = "wespeaker-ecapa-tdnn512-LM-v1"


def compute_fbank(wav_path: Path) -> np.ndarray:
    """
    Load a 16kHz mono WAV and compute Kaldi-style log-mel fbank features.

    Returns:
        np.ndarray of shape [T, 80], dtype float32, CMN-normalized.
    """
    samples, sr = sf.read(str(wav_path), dtype="float32", always_2d=False)

    # Ensure mono
    if samples.ndim > 1:
        samples = samples.mean(axis=1)

    # Resample if necessary (should not happen — FFmpeg guarantees 16kHz)
    if sr != 16000:
        import scipy.signal
        target_len = int(len(samples) * 16000 / sr)
        samples = scipy.signal.resample(samples, target_len).astype(np.float32)

    opts = knf.FbankOptions()
    opts.frame_opts.dither = 0.0
    opts.frame_opts.frame_length_ms = 25.0
    opts.frame_opts.frame_shift_ms = 10.0
    opts.frame_opts.window_type = "hamming"
    opts.frame_opts.remove_dc_offset = True
    opts.frame_opts.round_to_power_of_two = True
    opts.frame_opts.snip_edges = True
    opts.mel_opts.num_bins = 80
    opts.mel_opts.low_freq = 20.0
    opts.mel_opts.high_freq = 0.0  # 0 = Nyquist (8000 Hz at 16kHz)
    opts.use_energy = False

    fbank = knf.OnlineFbank(opts)
    # kaldi-native-fbank expects samples scaled to int16 range
    fbank.accept_waveform(16000, (samples * 32768).tolist())
    fbank.input_finished()

    frames = [fbank.get_frame(i) for i in range(fbank.num_frames_ready)]
    if not frames:
        raise ValueError(f"No fbank frames computed for {wav_path} — file too short?")

    mat = np.array(frames, dtype=np.float32)  # [T, 80]

    # CMN: subtract per-utterance mean across time axis
    mat -= mat.mean(axis=0, keepdims=True)
    return mat


def compute_embedding_from_fbank(
    feats: np.ndarray,
    session,  # onnxruntime.InferenceSession
) -> np.ndarray:
    """
    Run ONNX inference on precomputed fbank features.

    Args:
        feats: [T, 80] float32 fbank array
        session: loaded onnxruntime.InferenceSession

    Returns:
        L2-normalized embedding vector of shape [EMBEDDING_DIM].
    """
    inp = feats[np.newaxis, :, :]  # [1, T, 80]
    outputs = session.run(["embs"], {"feats": inp})
    emb = outputs[0][0].astype(np.float32)  # [512]
    norm = np.linalg.norm(emb)
    if norm > 0:
        emb = emb / norm
    return emb
