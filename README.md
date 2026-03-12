# KlarityApp — Personal AI Meeting Assistant

A **local-first macOS desktop application** that records meetings, transcribes them after the meeting ends, identifies speakers, and generates structured meeting notes — all without a meeting bot.

---

## Architecture

```
SwiftUI macOS App  →  Local FastAPI Backend  →  ElevenLabs / Resemblyzer / Ollama / OpenAI
```

| Layer     | Technology                         |
|-----------|-------------------------------------|
| Frontend  | Swift + SwiftUI (macOS)             |
| Backend   | Python 3.11 + FastAPI + Uvicorn     |
| Database  | SQLite via SQLAlchemy               |
| Audio     | FFmpeg (preprocessing), AVAudioEngine (recording) |
| STT       | ElevenLabs Scribe                   |
| Embeddings| Resemblyzer                         |
| LLM       | OpenAI / Anthropic / Gemini / Ollama|

---

## Repository Structure

```
KlarityApp/
├── docs/                           # PRD, architecture, build plan
├── storage/                        # Local data root (gitignored content)
├── apps/
│   └── macos/
│       └── PersonalAIMeetingAssistant/
│           ├── App/                # Entry point, ContentView, termination handler
│           ├── Models/             # Swift data models
│           ├── Services/           # APIClient, AudioRecorder, KeychainService,
│           │                       # BackendProcessManager
│           ├── ViewModels/         # Observable ViewModels
│           └── Features/
│               ├── Home/           # Meeting list + search
│               ├── Recording/      # Recording sheet
│               ├── MeetingDetail/  # Tabbed detail page + audio player
│               ├── Transcript/     # Transcript view + AudioPlayerView
│               ├── People/         # Known people library
│               └── Settings/       # Provider & storage configuration
├── scripts/
│   └── bundle_backend.sh           # Xcode build phase: copies venv into .app
└── backend/
    ├── app/
    │   ├── api/                    # FastAPI routers
    │   ├── core/                   # config.py
    │   ├── db/                     # database.py, schema.sql
    │   ├── models/                 # SQLAlchemy ORM models
    │   ├── schemas/                # Pydantic schemas
    │   ├── services/
    │   │   ├── audio/              # FFmpeg preprocessor
    │   │   ├── transcription/      # ElevenLabs provider + base
    │   │   ├── embeddings/         # Resemblyzer speaker embeddings
    │   │   ├── summarization/      # OpenAI / Ollama / Anthropic providers
    │   │   └── storage/            # File layout helpers
    │   ├── workers/                # Processing pipeline orchestration
    │   └── prompts/                # summary_prompt.txt
    ├── tests/
    ├── requirements.txt
    ├── pyproject.toml
    └── .env.example
```

For contributor expectations and workflow details, see [AGENTS.md](AGENTS.md).

---

## Quick Start

The backend runs **inside the `.app` bundle** — you do not start it separately. Just build and run in Xcode.

### 1. One-time setup (before first build)

```bash
# Install FFmpeg (required for audio preprocessing)
brew install ffmpeg

# Create the Python virtualenv and install all dependencies
cd backend
python3 -m venv venv
pip install -r requirements.txt

# Copy and configure environment variables
cp .env.example .env
# Edit .env — add your ElevenLabs and LLM API keys
```

### 2. Xcode build phase setup (one-time)

1. Target → **Build Phases** → **+** → **New Run Script Phase**
2. Paste the script path:
   ```
   "${SRCROOT}/../../../scripts/bundle_backend.sh"
   ```
   *(adjust depth to match your Xcode project location relative to the repo root)*
3. Uncheck **"Based on dependency analysis"** so it always runs
4. Move the phase to run **after Compile Sources**

Every subsequent `⌘R` or Archive will automatically copy `backend/app/` + `backend/venv/` into `.app/Contents/Resources/backend/`.

### 3. Run

Press `⌘R` in Xcode. The app launches, starts the embedded Python backend automatically (~2 second warmup), and shuts it down cleanly when you quit.

Backend API docs (during development): http://127.0.0.1:8765/docs

---

## Bundled Backend

The Python FastAPI backend is embedded inside the `.app` bundle and managed entirely by the Swift app:

```
KlarityApp.app/
└── Contents/
    ├── MacOS/KlarityApp          ← Swift binary
    └── Resources/
        └── backend/
            ├── app/              ← FastAPI source code
            └── venv/             ← Python virtualenv with all dependencies
```

| Component | Role |
|-----------|------|
| `BackendProcessManager.swift` | Finds the bundled venv, spawns `uvicorn`, terminates on quit |
| `AppTerminationHandler.swift` | Hooks `NSApplication.willTerminateNotification` for clean shutdown |
| `scripts/bundle_backend.sh` | Xcode build phase script — rsyncs backend into the bundle |

Users see a single `.app`. There is no separate server to start.

---

## Key Workflows

| Step | Actor | Description |
|------|-------|-------------|
| 1    | User  | Click **New Recording**, enter meeting title |
| 2    | App   | Create meeting record, start local audio capture |
| 3    | User  | Stop recording when meeting ends |
| 4    | Backend | Preprocess audio → Transcribe (ElevenLabs) → Embed speakers |
| 5    | User  | Review transcript, fix/assign speaker identities |
| 6    | User  | Click **Generate Summary & Tasks** when ready |
| 7    | Backend | Call selected LLM → save summary.md + tasks.json |

---

## Configuration

### Transcription
- Primary: **ElevenLabs Scribe** (`ELEVENLABS_API_KEY`)

### LLM Providers
| Provider   | Key / Endpoint         |
|------------|------------------------|
| Ollama     | `OLLAMA_ENDPOINT`      |
| OpenAI     | `OPENAI_API_KEY`       |
| Anthropic  | `ANTHROPIC_API_KEY`    |
| Gemini     | `GEMINI_API_KEY`       |

### Storage
Default storage: `~/Documents/AI-Meetings`

---

## Speaker Recognition

- Embeddings via **Resemblyzer** (d-vectors)
- Cosine similarity matching against known people library
- Thresholds configurable in Settings:
  - Suggest match: `0.75`
  - Auto-assign: `0.90`
  - Duplicate detection: `0.82`

---

## Running Tests

```bash
cd backend
pytest tests/ -v
```

---

## Important Design Constraints

- **No meeting bots** — records local audio only
- **No live transcription** in V1 — post-meeting processing only
- **Summary generation is always manual** — user clicks the button
- **All data stays local** unless cloud API is explicitly configured
- API keys for sensitive providers stored in **macOS Keychain** (Swift) and env variables (backend)
