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
| Audio capture | AVAudioEngine (Swift) |
| Audio preprocessing | FFmpeg (16kHz mono normalization) |
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
  audio.wav              # Original recording
  normalized.wav         # 16kHz mono (FFmpeg output)
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

1. **Record** — AVAudioEngine captures audio → saved as `audio.wav`
2. **Preprocess** — FFmpeg normalizes to 16kHz mono WAV
3. **Transcribe** — ElevenLabs Scribe returns timestamped segments with speaker IDs
4. **Embed** — Resemblyzer computes d-vectors per speaker cluster
5. **Match** — Cosine similarity against known people's voice embeddings
6. **Summarize** — LLM generates `summary.md` + extracts tasks

---

## Key Conventions

- **Backend:** All long-running operations (transcribe, embed, summarize) use FastAPI `BackgroundTasks`; endpoints return immediate confirmations
- **Backend:** Structured logging via `structlog`; configuration via Pydantic `Settings`
- **Frontend:** NavigationSplitView pattern (sidebar + detail); all HTTP calls go through `APIClient`
- **Linting:** Ruff for Python (`pyproject.toml`); run `ruff check backend/` before committing backend changes
- **Tests:** Place backend tests in `backend/tests/`; use `TestClient` from FastAPI for integration tests
- **No auto-commits:** Never commit without explicit user request
