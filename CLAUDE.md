# KlarityApp — CLAUDE.md

## Project Overview
KlarityApp is a **local-first macOS desktop app** for personal AI-powered meeting assistance. It records meetings locally, transcribes audio after the meeting ends (no meeting bot required), performs speaker diarization, and generates structured notes and action items via LLMs. All data stays on-device unless cloud APIs are explicitly configured.

---

## Architecture

**Two-process architecture:**
- **Swift/SwiftUI frontend** (macOS native) — recording, playback, UI
- **Python/FastAPI backend** — audio processing, transcription, speaker embeddings, LLM summarization, SQLite persistence

The Swift app spawns and manages the Python backend process via `BackendProcessManager`. They communicate over `http://127.0.0.1:8765`.

**Frontend pattern:** MVVM — `ObservableObject` ViewModels, `@Published` properties, global `AppState` environment object.

**Backend pattern:** Provider factory pattern for transcription and summarization (pluggable providers with a base class + `get_provider()` factory).

---

## Project Structure

```
KlarityApp/
├── apps/macos/PersonalAIMeetingAssistant/
│   ├── App/                  # Entry point, AppState, termination handler
│   ├── Models/               # Swift data models
│   ├── ViewModels/           # Observable state management
│   ├── Services/             # APIClient, AudioRecorder, KeychainService, BackendProcessManager
│   └── Features/
│       ├── Home/             # Meeting list + search
│       ├── Recording/        # Recording sheet
│       ├── MeetingDetail/    # Tabbed detail view
│       ├── Transcript/       # Transcript viewer + audio player
│       ├── People/           # Known people library
│       └── Settings/         # API keys, storage paths, thresholds
├── backend/
│   ├── app/
│   │   ├── api/              # FastAPI routers: meetings, transcript, people, summaries, health
│   │   ├── core/config.py    # Pydantic Settings (reads .env)
│   │   ├── db/               # SQLAlchemy setup + init
│   │   ├── models/           # ORM: Meeting, Person, TranscriptSegment, SpeakerCluster, Summary, Task, Job, Setting
│   │   ├── schemas/          # Pydantic request/response schemas
│   │   ├── services/
│   │   │   ├── audio/        # FFmpeg preprocessor (→ 16kHz mono)
│   │   │   ├── transcription/# ElevenLabs provider + base abstraction
│   │   │   ├── embeddings/   # Resemblyzer d-vector speaker matching
│   │   │   ├── summarization/# OpenAI / Anthropic / Gemini / Ollama providers
│   │   │   └── storage/      # File layout helpers
│   │   ├── workers/          # Processing pipeline orchestration
│   │   └── prompts/          # LLM system prompts
│   ├── tests/                # pytest suite (meetings, audio, people, settings)
│   ├── requirements.txt
│   ├── pyproject.toml        # Ruff + pytest config
│   └── .env.example
├── scripts/bundle_backend.sh  # Xcode build phase script
└── docs/                      # PRD, architecture, build plan
```

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | Swift 5 + SwiftUI (macOS) |
| Backend | Python 3.11+ FastAPI + Uvicorn |
| Database | SQLite via SQLAlchemy ORM |
| Audio capture — system | Core Audio Process Tap (`CATapDescription` + `AudioHardwareCreateProcessTap`, macOS 14.2+) via aggregate device + `AudioDeviceCreateIOProcIDWithBlock` |
| Audio capture — mic | `AVAudioEngine.inputNode` tap with lazy `AVAudioConverter` |
| Audio mixing | Streaming chunk-by-chunk float32 average of two temp WAV files → `audio.wav` (post-recording, no FFmpeg, ~32KB memory) |
| Audio preprocessing | FFmpeg (16kHz mono normalization, largely no-op since source is already 16kHz mono) |
| Speech-to-text | ElevenLabs Scribe API (speaker diarization) |
| Speaker embeddings | Resemblyzer (d-vectors, cosine similarity) |
| LLM providers | OpenAI, Anthropic, Google Gemini, Ollama |
| Xcode project | `apps/macos/KlarityApp.xcodeproj` |

---

## Setup

```bash
# System dependency
brew install ffmpeg

# Python backend
cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Edit .env: set ELEVENLABS_API_KEY and at least one LLM key
```

**Xcode build phase** (one-time):
- Target → Build Phases → New Run Script Phase
- Script path: `"${SRCROOT}/../../../scripts/bundle_backend.sh"`
- Uncheck "Based on dependency analysis"
- Place after "Compile Sources"

---

## Run & Build

```bash
# Build + run frontend (launches embedded backend automatically)
# Press ⌘R in Xcode

# Backend dev mode (standalone, for API testing)
cd backend && uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload

# Backend API docs (dev only)
open http://127.0.0.1:8765/docs

# Run tests
cd backend && pytest tests/ -v
```

---

## Configuration (`.env`)

| Key | Default | Notes |
|-----|---------|-------|
| `BASE_STORAGE_DIR` | `~/Documents/AI-Meetings` | Local data root |
| `ELEVENLABS_API_KEY` | — | Required for transcription |
| `OPENAI_API_KEY` | — | LLM provider |
| `ANTHROPIC_API_KEY` | — | LLM provider |
| `GEMINI_API_KEY` | — | LLM provider |
| `OLLAMA_ENDPOINT` | — | Local Ollama instance |
| `DEFAULT_LLM_PROVIDER` | `openai` | |
| `DEFAULT_LLM_MODEL` | `gpt-4o` | |
| `SPEAKER_SUGGEST_THRESHOLD` | `0.75` | Cosine similarity: suggest match |
| `SPEAKER_AUTO_THRESHOLD` | `0.90` | Auto-assign without prompt |
| `SPEAKER_DUPLICATE_THRESHOLD` | `0.82` | Dedup same speaker clusters |
| `BACKEND_PORT` | `8765` | |
| `LOG_LEVEL` | `info` | |

---

## Data Storage Layout (`~/Documents/AI-Meetings/`)

```
meetings/{meeting_id}/
  audio.wav              # Mixed recording (system + mic, 16kHz mono int16 PCM)
  normalized.wav         # 16kHz mono (FFmpeg output, largely identical to audio.wav)
  transcript.raw.json    # Raw ElevenLabs response
  transcript.json        # Structured speaker segments
  summary.json           # LLM structured output
  summary.md             # Human-readable summary
  tasks.json             # Extracted action items
voices/{person_id}.npy   # Resemblyzer speaker embedding (NumPy)
logs/
  app.db                 # SQLite database
  backend.log            # Backend process log
exports/                 # User-exported artifacts
```

---

## Meeting Processing Pipeline

Meeting status flow:
```
created → recording → preprocessing → transcribing → matching_speakers → transcript_ready → summarizing → complete
                                                                                                          ↓
                                                                                                        failed
```

1. **Record** — Two independent capture paths run in parallel:
   - **System audio:** Core Audio Process Tap (`CATapDescription`) → aggregate device → `AudioDeviceIOProcID` → manual mono downmix → `AVAudioConverter` → `audio_sys_tmp_{uuid}.wav` (16kHz mono int16)
   - **Mic:** `AVAudioEngine.inputNode` tap → lazy `AVAudioConverter` (created on first callback) → `audio_mic_tmp_{uuid}.wav` (16kHz mono int16)
2. **Mix** — On stop, both writer queues are drained, then the two temp WAVs are mixed chunk-by-chunk (float32 average, 4096 frames at a time) into `audio.wav`. Falls back to system-audio-only if mic captured nothing. Temp files are deleted.
3. **Preprocess** — FFmpeg normalizes `audio.wav` to `normalized.wav` (already 16kHz mono, so this is largely a no-op)
3. **Transcribe** — ElevenLabs Scribe returns timestamped segments with speaker IDs
4. **Embed** — Resemblyzer computes d-vectors per speaker cluster
5. **Match** — Cosine similarity against known people's voice embeddings
6. **Summarize** — LLM generates `summary.md` + extracts tasks

---

## Audio Recording Architecture (Hard-Won — Do Not Change Without Reading This)

All recording logic lives in `Services/AudioRecorder.swift`. The architecture below was finalized after multiple days of debugging real failures (deadlocks, 2× speed playback, silent mic, crashes). Every rule here maps to a confirmed failure.

### Two-Path Design

System audio and mic are captured on completely separate paths into separate temp WAV files. They cannot be combined into a single aggregate device because when the aggregate's main sub-device is an output device (required for the tap's clock), macOS does not surface mic input in the IOProc — mic buffers simply don't appear. Two paths is the only solution.

Do **not** use `SCStream` (ScreenCaptureKit) for system audio. It silently stops delivering audio in audio-only mode after ~2–5 min on Sonoma/Sequoia. This is a confirmed platform bug with no workaround.

### Startup Order (non-negotiable — each step depends on the previous)

```
0. stopAllCapture()
      Full teardown of any previous recording state (tap, aggregate, engine, listeners).
      Ensures clean state before starting. Prevents leftover resources from a crashed
      or incomplete previous recording from interfering.

1. destroyLeftoverAggregateDevice()
      Enumerate HAL devices by UID AND name, destroy any leftover aggregate from a prior
      crashed session. Creating a new aggregate with the same UID silently fails.
      Also destroys aggregates matching the name "KlarityMeetingRecorder".

2. setupMicCapture()  ← AVAudioEngine starts HERE, before the aggregate is created
      a. Check mic permission inline (non-fatal — denied = skip mic, don't throw)
      b. Check default input device via kAudioHardwarePropertyDefaultInputDevice
         (NOT inputNode.inputFormat — returns 0Hz before start)
      c. engine = AVAudioEngine()
      d. let inputNode = engine.inputNode   ← MUST access on MainActor BEFORE start()
         (inputNode is lazy — not accessing it before start() → graph empty → crash)
      e. inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil)
         (nil format — let AVAudioEngine negotiate hardware format during start)
         (create AVAudioConverter lazily on first callback using buffer.format,
          which is always the true delivered format)
      f. engine.start() dispatched to DispatchQueue.global() — NOT MainActor
         (engine.start() calls prepare() which blocks on HAL callbacks;
          if called on MainActor it deadlocks waiting for callbacks that can't fire)

3. AudioHardwareCreateProcessTap(CATapDescription(stereoGlobalTapButExcludeProcesses: []))
      muteBehavior = .unmuted
      tapDesc.uuid.uuidString  ← lowercase .uuid, not .UUID

4. AudioHardwareCreateAggregateDevice(props)
      Required keys:
        kAudioAggregateDeviceMainSubDeviceKey: outputUID
        kAudioAggregateDeviceTapListKey: [{kAudioSubTapUIDKey: tapUID,
                                           kAudioSubTapDriftCompensationKey: true}]
        kAudioAggregateDeviceSubDeviceListKey: [{kAudioSubDeviceUIDKey: outputUID}]
        kAudioAggregateDeviceIsPrivateKey: true
        kAudioAggregateDeviceIsStackedKey: false
      NO mic sub-device — won't appear in IOProc anyway, just wastes resources

5. Task.sleep(150ms)  ← wait for HAL to settle after aggregate creation

6. Query kAudioDevicePropertyNominalSampleRate from aggregateDeviceID  ← CRITICAL
      NEVER query from the output device upfront.
      AVAudioEngine loads VPIO (Voice IO), which can change the output device's HAL
      sample rate between your upfront query and aggregate creation. The aggregate
      inherits the post-VPIO rate. Querying the aggregate AFTER creation + sleep gives
      the actual rate the IOProc will deliver. Using a stale pre-VPIO rate for the
      AVAudioConverter causes 2× speed playback.

      Console evidence VPIO is active: "Disabling HAL Voice Isolation support due to
      app's use of existing chat flavors"

      Also do NOT use:
        kAudioDevicePropertyStreamFormat (INPUT scope) → returns 2× real rate for tap aggregate
        kAudioTapPropertyFormat → also returns wrong/doubled value

7. Create AVAudioConverter(Float32 @ deviceSampleRate → Int16 @ 16_000)
8. AudioDeviceCreateIOProcIDWithBlock + AudioDeviceStart
```

### IOProc (system audio, real-time thread)

Receives `AudioBufferList` containing Float32 non-interleaved buffers. Manually downmixes all channels to mono Float32, wraps in `AVAudioPCMBuffer`, converts to Int16 @ 16kHz, writes to `audio_sys_tmp.wav` via a serial `DispatchQueue`.

### Post-Recording Mix

After both writer queues drain: reads both temp WAVs in 4096-frame Float32 chunks, averages sample-by-sample, converts to Int16, writes `audio.wav`. ~32KB working memory. If mic is empty, system audio is moved directly to `audio.wav`.

### Output Format

`AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)`

Both temp files and final `audio.wav` use this format. **No AAC, no .caf, no Float32 WAV.**

### Reliability Safeguards (added 2026-04-12)

1. **Thread safety**: `hasSysAudio`, `hasMicAudio`, and `isPaused` use `OSAllocatedUnfairLock<Bool>` — they are accessed from both the real-time IOProc thread and MainActor. Bare `Bool` properties can produce stale reads across threads, causing `stopRecording()` to skip mixing or discard captured audio.

2. **Full teardown before each recording**: `setupAndStart()` calls `stopAllCapture()` before creating any new resources. This prevents leftover state from a previous recording (or crashed session) from interfering. `destroyLeftoverAggregateDevice()` now matches by both UID and name.

3. **Retry for aggregate device creation**: `AudioHardwareCreateAggregateDevice` is retried up to 3 times with 100ms delay. Transient failures are common after a previous recording's cleanup.

4. **State machine**: Recording state transitions are enforced — `idle → preparing → recording → idle` and `recording → paused → recording/idle`. Invalid transitions log warnings. `controlState` and `isPreparingCapture` are removed; the single `state` property is the source of truth.

5. **Health check timer**: 3 seconds after recording starts, checks whether `hasSysAudio` and `hasMicAudio` are true. If not, logs a diagnostic warning (doesn't stop recording — just informs). A 10-second periodic stall detector warns if audio stops flowing during recording.

6. **Audio device change detection**: Core Audio property listeners for `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDefaultInputDevice` are registered during recording. Changes (headphones unplugged, Bluetooth disconnected) log a warning. No automatic restart — that's a future iteration.

7. **App lifecycle cleanup**: `AudioRecorder.cleanup()` is called from `NSApplication.willTerminateNotification` to release Core Audio taps and aggregate devices even if the app is killed mid-recording.

---

## Key Conventions

- **Backend:** All long-running operations (transcribe, embed, summarize) use FastAPI `BackgroundTasks`; endpoints return immediate confirmations
- **Backend:** Structured logging via `structlog`; configuration via Pydantic `Settings`
- **Frontend:** NavigationSplitView pattern (sidebar + detail); all HTTP calls go through `APIClient`
- **Linting:** Ruff for Python (`pyproject.toml`); run `ruff check backend/` before committing backend changes
- **Tests:** Place backend tests in `backend/tests/`; use `TestClient` from FastAPI for integration tests
- **No auto-commits:** Never commit without explicit user request
