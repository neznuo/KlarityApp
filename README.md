# KlarityApp — Personal AI Meeting Assistant

A **local-first macOS desktop application** that records meetings, transcribes them after the meeting ends, identifies speakers, and generates structured meeting notes — all without a meeting bot.

---

## Architecture

```
SwiftUI macOS App  →  Local FastAPI Backend  →  ElevenLabs / ONNX / Ollama / OpenAI
```

| Layer     | Technology                         |
|-----------|-------------------------------------|
| Frontend  | Swift + SwiftUI (macOS)             |
| Backend   | Python 3.11 + FastAPI + Uvicorn     |
| Database  | SQLite via SQLAlchemy               |
| Audio capture | Core Audio Tap `CATapDescription` (system audio, macOS 14.2+) + `AVAudioEngine` (mic) |
| Audio mixing  | AVMutableComposition + AVAssetExportSession (post-recording mix to .m4a) |
| Audio preprocessing | FFmpeg (16kHz mono normalization) |
| STT       | ElevenLabs Scribe                   |
| Embeddings| WeSpeaker ECAPA-TDNN512-LM (ONNX, torch-free) |
| LLM       | OpenAI / Anthropic / Gemini / Ollama|
| Calendar  | Google Calendar API v3 + Microsoft Graph (PKCE OAuth, Swift-only) |

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
│           │                       # BackendProcessManager, CalendarService
│           ├── ViewModels/         # Observable ViewModels
│           └── Features/
│               ├── Home/           # Meeting list + search
│               ├── Recording/      # Recording sheet
│               ├── MeetingDetail/  # Tabbed detail page + audio player
│               ├── Transcript/     # Transcript view + AudioPlayerView
│               ├── People/         # Known people library
│               └── Settings/       # Provider & storage configuration
├── scripts/
│   └── bundle_backend.sh           # Xcode build phase: copies venv + models into .app
├── .gitattributes                  # Marks .onnx and .npy files as binary
├── tasks.md                        # Active development task tracker
└── backend/
    ├── models/
    │   └── speaker_encoder.onnx    # WeSpeaker ECAPA-TDNN512-LM (24 MB, bundled)
    ├── app/
    │   ├── api/                    # FastAPI routers
    │   ├── core/                   # config.py
    │   ├── db/                     # database.py, schema.sql
    │   ├── models/                 # SQLAlchemy ORM models
    │   ├── schemas/                # Pydantic schemas
    │   ├── services/
    │   │   ├── audio/              # FFmpeg preprocessor
    │   │   ├── transcription/      # ElevenLabs provider + base
    │   │   ├── embeddings/         # ONNX speaker embeddings (audio_utils.py + speaker_embedding.py)
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

Every subsequent `⌘R` or Archive will automatically copy `backend/app/`, `backend/venv/`, and `backend/models/` into `.app/Contents/Resources/backend/`.

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
            ├── models/           ← speaker_encoder.onnx (ECAPA-TDNN512-LM, 24 MB)
            └── venv/             ← Python virtualenv with all dependencies (~580 MB)
```

The entire backend — Python packages, ONNX model, and source — is self-contained in the bundle. Users need no Python, pip, or internet connection. Distribute by sharing the `.app` directly or wrapping it in a `.dmg`.

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
| 1    | User  | Click **New Recording** — upcoming calendar events appear as one-tap pills to auto-fill the title |
| 2    | App   | Create meeting record (with optional `calendar_event_id`/`calendar_source`), start capture: Core Audio Tap (system audio) + AVAudioEngine (mic) |
| 3    | User  | Stop recording when meeting ends |
| 4    | App   | Mix system + mic temp files into final `audio.m4a` via AVMutableComposition export |
| 5    | Backend | Preprocess audio → Transcribe (ElevenLabs) → Embed speakers |
| 6    | User  | Review transcript, fix/assign speaker identities |
| 7    | User  | Click **Generate Summary & Tasks** when ready |
| 8    | Backend | Call selected LLM → save summary.md + tasks.json |

---

## Configuration

### Calendar Sync (optional)

Connects Google Calendar and/or Outlook so upcoming meetings appear as auto-fill pills in the New Recording sheet. All OAuth tokens are stored locally in the macOS Keychain — nothing is sent to the backend except a connected/disconnected boolean flag.

#### 1. Register OAuth apps

**Google Calendar**
1. Go to [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials
2. Create an **OAuth 2.0 Client ID**, application type **iOS** (works for macOS PKCE flows)
3. Set the redirect URI to: `klarity://oauth/google/callback`
4. Enable the **Google Calendar API** for the project

**Microsoft Outlook**
1. Go to [Azure Portal](https://portal.azure.com/) → App registrations → New registration
2. Add a redirect URI (platform: **Mobile and desktop applications**): `klarity://oauth/microsoft/callback`
3. Under API permissions, add `Calendars.Read` and `offline_access` (Microsoft Graph)

#### 2. Add client IDs to the app

Open `apps/macos/PersonalAIMeetingAssistant/App/Info.plist` and replace the placeholder values:

```xml
<key>KlarityGoogleClientID</key>
<string>YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com</string>
<key>KlarityMicrosoftClientID</key>
<string>YOUR_AZURE_APPLICATION_CLIENT_ID</string>
```

#### 3. Connect in-app

Open **Settings → Calendar Sync** and click **Connect** next to each provider. A browser window will open for OAuth authorization. Once approved, upcoming meetings (next 24 hours) appear as pills when you start a new recording.

---

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

- Embeddings via **WeSpeaker ECAPA-TDNN512-LM** (192-dim d-vectors, ONNX, torch-free)
- Preprocessing: Kaldi-style log-mel fbank (80 bins, 25ms frame, 10ms hop) via `kaldi-native-fbank`
- Cosine similarity matching against known people library (`voices/*.npy`)
- Thresholds configurable in `.env` / Settings:
  - Suggest match: `SPEAKER_SUGGEST_THRESHOLD=0.75`
  - Auto-assign: `SPEAKER_AUTO_ASSIGN_THRESHOLD=0.90`
  - Duplicate detection: `SPEAKER_DUPLICATE_THRESHOLD=0.82`
- Migration: if the speaker model is updated, existing voice profiles must be re-enrolled. Check `GET /people/embedding-status` for compatibility status.

> **Note:** Thresholds are calibrated for the ECAPA-TDNN512-LM model. If you swap `backend/models/speaker_encoder.onnx`, recalibrate using real voice samples — see `backend/models/README.md`.

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
- API keys and OAuth tokens for all providers stored in **macOS Keychain** (Swift) and env variables (backend)
- **Calendar OAuth is handled entirely in Swift** — backend only stores `calendar_event_id` and `calendar_source` string fields on the Meeting record

## Build App Locally
./scripts/build.sh 2>&1 | tail -30
