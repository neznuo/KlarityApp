# TASK-001 — Replace resemblyzer with ONNX Speaker Embeddings

## Summary

Replace the `resemblyzer` library (which pulls in `torch`, `numba`, `librosa`, `llvmlite`, `sympy`) with a lightweight ONNX-based speaker embedding pipeline. This reduces the bundled `.app` size from ~1.1 GB to ~200–250 MB with no user-visible feature change.

**Estimated effort:** 3–5 days
**Branch:** `chore/onnx-speaker-embeddings`
**Status:** Planned

---

## Why

| Package removed | Size saved |
|---|---|
| torch | 402 MB |
| llvmlite | 112 MB |
| scipy (partial — still needed for cosine math) | ~60 MB |
| numba | 29 MB |
| librosa | ~15 MB |
| sympy (torch transitive dep) | 76 MB |
| **Total** | **~694 MB** |

`resemblyzer` uses a GE2E-style model that requires PyTorch for inference. Replacing it with the same model (or equivalent) exported to ONNX removes the torch dependency entirely and allows using `onnxruntime` (~15 MB) instead.

---

## Scope

### In scope
- Replace `resemblyzer.VoiceEncoder` with ONNX runtime inference
- Re-implement the audio preprocessing pipeline (mel spectrogram → sliding windows → mean-pool) in pure `numpy` + `scipy`
- Bundle the ONNX model file in the repo (`backend/models/speaker_encoder.onnx`)
- Update `requirements.txt` — remove resemblyzer, torch, librosa, numba; add onnxruntime
- Update `bundle_backend.sh` to exclude unused packages
- Provide a one-time migration utility to invalidate and re-generate stored voice embeddings
- Update `.env.example` and CLAUDE.md architecture table

### Out of scope
- Changing the speaker matching logic (cosine similarity, thresholds) — those stay identical
- Changing the ElevenLabs diarization step — that is unaffected
- Changing how embeddings are stored (`.npy` files) — same format, different values

---

## Impact Analysis

| Feature | Impact | Notes |
|---|---|---|
| Speaker matching (known people) | Neutral | Same cosine similarity logic, different model |
| Speaker deduplication within meetings | Neutral | Same `check_duplicates()` logic |
| ElevenLabs transcription + diarization | None | Completely separate service |
| Existing stored voice embeddings (`voices/*.npy`) | **Breaking** | Embeddings are model-specific — old files are incompatible |
| Recording | None | Frontend audio pipeline untouched |
| Summarization / LLM | None | |
| Transcription playback | None | |
| Threshold settings in `.env` | Requires retuning | Scores from a different model have a different distribution; the 0.75 / 0.90 / 0.82 defaults will need empirical revalidation |

---

## Subtasks

### TASK-001-A: Select and export ONNX model

**Goal:** Identify a pretrained speaker verification model available as ONNX (or exportable), validate its embedding quality is suitable.

**Steps:**
1. Evaluate these candidates:
   - **WeSpeaker ResNet293** — strong accuracy, ~20 MB ONNX, widely used in production
   - **SpeechBrain ECAPA-TDNN** — excellent speaker verification, exportable via `torch.onnx.export`
   - **Silero speaker verification model** — very small (~5 MB), lower accuracy
2. For each candidate: check input format (expected sample rate, frame size, normalization), output embedding dimension
3. Run a quick accuracy check: compute embeddings for 2–3 known voice samples; verify same-speaker similarity > 0.80, different-speaker < 0.60
4. Export the chosen model to ONNX: `torch.onnx.export(model, dummy_input, "speaker_encoder.onnx", opset_version=17)`
5. Place the final `.onnx` file at `backend/models/speaker_encoder.onnx`

**Acceptance criteria:**
- ONNX model file is <25 MB
- Inference runs without torch using `onnxruntime` on macOS (CPU provider)
- Same-speaker cosine similarity consistently > 0.78 on test samples

**Files touched:**
- `backend/models/speaker_encoder.onnx` (new)

---

### TASK-001-B: Implement ONNX-based audio preprocessing

**Goal:** Re-implement the audio feature extraction that `resemblyzer` + `librosa` currently handle, using only `numpy` and `scipy`.

**Context:** `resemblyzer` preprocessing does:
1. Loads WAV at 16kHz mono (already guaranteed by FFmpeg preprocessor)
2. Applies a pre-emphasis filter
3. Computes mel spectrogram (80 mel bins, 25ms window, 10ms hop)
4. Normalizes per-utterance
5. Slices into partial utterances (160-frame windows, 80-frame step)
6. Runs the encoder on each slice, then mean-pools all slice embeddings

**Steps:**
1. Implement `preprocess_audio(wav_path: Path) -> np.ndarray` in a new file `backend/app/services/embeddings/audio_utils.py`:
   - Load WAV with `soundfile` (already a transitive dep)
   - Pre-emphasis: `y[n] = x[n] - 0.97 * x[n-1]`
   - FFT-based mel spectrogram with `scipy.signal` — compute STFT, apply mel filterbank (use `numpy` to build the filterbank matrix), log-compress
   - Normalize: subtract mean, divide by std per utterance
   - Slice into windows
2. Match the exact hyperparameters of the chosen ONNX model's training preprocessing (these vary by model — check the model card)
3. Unit-test: feed the same WAV through the new preprocessing and through `resemblyzer.preprocess_wav`, verify mel spectrogram values are equivalent within floating-point tolerance

**Acceptance criteria:**
- `audio_utils.py` has no imports of `torch`, `librosa`, `numba`
- Mel spectrogram output matches resemblyzer's within ±1e-4 (or matches the new model's expected preprocessing exactly)
- Works on the existing 16kHz mono WAVs produced by FFmpeg

**Files touched:**
- `backend/app/services/embeddings/audio_utils.py` (new)

---

### TASK-001-C: Rewrite SpeakerEmbeddingService

**Goal:** Replace `resemblyzer.VoiceEncoder` usage in `speaker_embedding.py` with ONNX inference, keeping the public API identical so `processing_worker.py` requires zero changes.

**Steps:**
1. In `backend/app/services/embeddings/speaker_embedding.py`:
   - Remove imports of `resemblyzer`
   - Add `import onnxruntime as ort`
   - In `_get_encoder()`: load the ONNX session once — `ort.InferenceSession("backend/models/speaker_encoder.onnx", providers=["CPUExecutionProvider"])`
   - In `compute_embedding(audio_path)`:
     - Call `preprocess_audio(audio_path)` from `audio_utils.py` to get mel slices
     - Run each slice through the ONNX session: `session.run(output_names, {"input": slice})`
     - Mean-pool the per-slice embeddings to get the utterance embedding
     - L2-normalize the final embedding (standard for cosine similarity matching)
2. Keep all other methods (`save_embedding`, `load_embedding`, `find_best_match`, `check_duplicates`) completely unchanged — they operate on `np.ndarray` and are model-agnostic

**Acceptance criteria:**
- `speaker_embedding.py` has no reference to `resemblyzer`, `torch`, or `librosa`
- `SpeakerEmbeddingService` public API is unchanged (same method signatures and return types)
- `processing_worker.py` requires no changes
- Embedding dimension is documented in a module-level constant: `EMBEDDING_DIM = 256` (or whatever the model uses)

**Files touched:**
- `backend/app/services/embeddings/speaker_embedding.py` (modified)
- `backend/app/services/embeddings/audio_utils.py` (new — from TASK-001-B)

---

### TASK-001-D: Update dependencies and bundle script

**Goal:** Remove heavy packages from `requirements.txt` and ensure the bundle script doesn't copy unnecessary files.

**Steps:**
1. In `backend/requirements.txt`:
   - Remove: `resemblyzer`, `librosa`
   - Add: `onnxruntime>=1.17.0`, `soundfile>=0.12.0`
   - Keep: `numpy`, `scipy` (still needed)
   - Verify no other code in the backend imports `torch`, `librosa`, `numba` — run `grep -r "import torch\|import librosa\|import numba" backend/app/`
2. Rebuild the venv: `cd backend && pip install -r requirements.txt`
3. Verify the new venv size: `du -sh backend/venv/`
4. In `scripts/bundle_backend.sh`: add `--exclude` for any build artifacts from the old packages if needed (e.g. `.dist-info` folders from removed packages don't linger)
5. Rebuild the `.app` in Xcode and verify the bundle size

**Acceptance criteria:**
- `backend/venv/` is < 300 MB
- Built `.app` is < 350 MB
- `pip install -r requirements.txt` completes without errors on a clean venv
- No references to removed packages remain in `backend/app/`

**Files touched:**
- `backend/requirements.txt`
- `scripts/bundle_backend.sh` (minor, if needed)

---

### TASK-001-E: Voice embedding migration

**Goal:** Handle the breaking change — existing `voices/*.npy` files (computed by resemblyzer) are incompatible with the new model's embeddings.

**Steps:**
1. Add a version marker file: `voices/embedding_model.txt` containing the model name and version (e.g., `wespeaker-resnet293-v1`)
2. On backend startup (in `app/main.py` lifespan or a startup check), detect if `embedding_model.txt` is missing or contains a different model name:
   - If mismatch: log a warning `"Speaker embeddings are from a different model and must be re-enrolled"`
   - Do NOT silently delete files — just warn and set a flag
3. In the People API (`app/api/people.py`), expose a `GET /people/embedding-status` endpoint that returns:
   - `{ "model": "wespeaker-resnet293-v1", "needs_reenrollment": true/false, "affected_people": [...] }`
4. Add a re-enrollment endpoint or document the manual steps (delete `voices/{person_id}.npy`, then re-register voice via the existing People flow)
5. Update the Settings UI hint text to explain voice re-enrollment (if needed — check Settings view in Swift)

**Acceptance criteria:**
- App starts cleanly even when old `.npy` files exist — no crash
- A clear warning is logged when stale embeddings are detected
- `GET /people/embedding-status` returns accurate status
- The existing People re-enrollment flow (uploading a voice sample) correctly overwrites the old `.npy` with a new embedding

**Files touched:**
- `backend/app/main.py` (startup check)
- `backend/app/api/people.py` (new status endpoint)
- `backend/app/schemas/` (response schema for status endpoint)

---

### TASK-001-F: Retune similarity thresholds

**Goal:** Validate and adjust the cosine similarity thresholds in `.env` for the new model.

**Context:** Current thresholds were empirically set for resemblyzer's GE2E model:
- `SPEAKER_SUGGEST_THRESHOLD=0.75` — suggest a match to the user
- `SPEAKER_AUTO_THRESHOLD=0.90` — auto-assign without prompt
- `SPEAKER_DUPLICATE_THRESHOLD=0.82` — merge duplicate clusters

Different models produce scores with different distributions. These numbers may need adjustment.

**Steps:**
1. Record or gather at least 3 short voice samples per person (ideally 2–3 different people)
2. Compute pairwise cosine similarities using the new ONNX model:
   - Same-speaker pairs: should cluster around a certain value
   - Different-speaker pairs: should cluster around a lower value
3. Pick new threshold values:
   - `SPEAKER_AUTO_THRESHOLD`: just below the minimum same-speaker score
   - `SPEAKER_SUGGEST_THRESHOLD`: midpoint between same-speaker and different-speaker clusters
   - `SPEAKER_DUPLICATE_THRESHOLD`: around the 90th percentile of same-speaker scores
4. Update `.env.example` with the new defaults and a comment explaining they are model-specific
5. Document the threshold values and the model they were calibrated for in `docs/tasks/TASK-001-threshold-calibration.md`

**Acceptance criteria:**
- At least 5 same-speaker and 5 different-speaker pairs tested
- False positive rate (wrong auto-assignment) < 5% on test samples
- New defaults documented in `.env.example` with a comment

**Files touched:**
- `backend/.env.example`
- `docs/tasks/TASK-001-threshold-calibration.md` (new)

---

### TASK-001-G: Testing and validation

**Goal:** Ensure the full pipeline works end-to-end with the new embedding engine before marking the task complete.

**Steps:**
1. Run existing backend test suite: `cd backend && pytest tests/ -v` — all tests must pass
2. Manual end-to-end test:
   - Record a short meeting (2 speakers minimum)
   - Verify transcript is generated with speaker labels
   - Verify speaker matching runs and produces a result (even if thresholds need tuning)
   - Verify the People library flow: register a voice → record a new meeting → confirm auto-match fires
3. Verify app bundle size: build in Xcode Release mode, check `.app` size in Finder
4. Smoke-test on a clean machine (no system Python packages) — the app must be fully self-contained

**Acceptance criteria:**
- All `pytest` tests pass
- Full recording → transcription → speaker matching pipeline works
- `.app` bundle < 350 MB
- No `torch`, `resemblyzer`, `librosa`, or `numba` in the bundled `Resources/backend/venv/`

---

## Dependency Graph

```
TASK-001-A (choose + export ONNX model)
    └── TASK-001-B (audio preprocessing)
            └── TASK-001-C (rewrite SpeakerEmbeddingService)
                    ├── TASK-001-D (update deps + bundle)
                    ├── TASK-001-E (migration)
                    └── TASK-001-F (retune thresholds)
                            └── TASK-001-G (testing + validation)
```

## Notes

- The ONNX model file should be committed to the repo (it's ~5–20 MB, acceptable for a binary asset at this size). Add it to `.gitattributes` as a binary if needed.
- `onnxruntime` on macOS uses the CPU execution provider by default. Apple Silicon also supports the CoreML execution provider via `onnxruntime-extensions` for faster inference — not required but a nice future improvement.
- If WeSpeaker is chosen, the pretrained ONNX weights are available at the WeSpeaker GitHub releases page — no need to train or export manually.
