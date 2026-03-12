# Running KlarityApp

## Prerequisites

Install these once on your Mac before doing anything else.

| Tool | Install command |
|------|----------------|
| Xcode 15+ | Mac App Store |
| Python 3.11+ | `brew install python@3.11` |
| FFmpeg | `brew install ffmpeg` |
| Homebrew | [brew.sh](https://brew.sh) |

---

## First-Time Setup

Run these steps once after cloning the repo. You will not need to repeat them.

### 1. Create the Python virtualenv

```bash
cd backend
python3 -m venv venv
pip install -r requirements.txt
```

This installs FastAPI, Uvicorn, Resemblyzer, the ElevenLabs SDK, OpenAI, Anthropic, and all other backend dependencies into a self-contained `venv/` folder.

### 2. Configure environment variables

```bash
cp .env.example .env
```

Open `backend/.env` and fill in at minimum:

```
ELEVENLABS_API_KEY=your_key_here
```

For LLM summarization, add whichever providers you plan to use:

```
OPENAI_API_KEY=...
ANTHROPIC_API_KEY=...
OLLAMA_ENDPOINT=http://localhost:11434   # no key needed for local Ollama
```

If you use Ollama, make sure it is running: `ollama serve`

### 3. Create an Xcode project

The Swift source files are under `apps/macos/PersonalAIMeetingAssistant/`. You need to wrap them in an Xcode project:

1. Open Xcode → **File → New → Project** → **macOS → App**
2. Set:
   - **Product Name**: `KlarityApp`
   - **Bundle Identifier**: `com.klarity.meeting-assistant`
   - **Interface**: SwiftUI
   - **Language**: Swift
3. Choose `apps/macos/PersonalAIMeetingAssistant/` as the project location (so the `.xcodeproj` sits alongside the source folders)
4. Drag all source folders into the Xcode project navigator:
   - `App/`
   - `Models/`
   - `Services/`
   - `ViewModels/`
   - `Features/`
5. In **Signing & Capabilities**, select your Apple developer team

### 4. Add the backend bundle build phase

This is the step that copies the Python backend + venv into the `.app` at build time.

1. In Xcode: **Target → Build Phases → "+" → New Run Script Phase**
2. Paste this into the script body:
   ```bash
   "${SRCROOT}/../../../scripts/bundle_backend.sh"
   ```
   > Adjust the relative path if your `.xcodeproj` is at a different depth from the repo root. The script lives at `scripts/bundle_backend.sh` relative to the repo root.
3. **Uncheck** "Based on dependency analysis"
4. Drag the new phase to run **after Compile Sources**

### 5. Add required macOS permissions

In **Signing & Capabilities → + Capability**, add:

- **Microphone** — required for recording
- **App Sandbox** — if enabled, also add **Outgoing Connections (Client)** so the app can reach ElevenLabs / OpenAI

In `Info.plist`, add:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>KlarityApp records meeting audio from your microphone.</string>
```

---

## Building the App

### Debug build (development)

Press **⌘R** in Xcode.

What happens:
1. Xcode compiles the Swift app
2. The Run Script build phase runs `bundle_backend.sh`, which rsyncs `backend/app/` and `backend/venv/` into `.app/Contents/Resources/backend/`
3. The app launches
4. `BackendProcessManager` finds the bundled venv and spawns `uvicorn` on `127.0.0.1:8765`
5. After ~2 seconds, the app confirms the backend is reachable and shows the main window

### Release / Archive build

1. **Product → Archive**
2. Xcode runs the same build phase — the venv is bundled into the archive
3. Distribute via **Distribute App → Copy App** for personal use

> The venv adds ~200–400 MB to the bundle depending on installed packages. This is expected for a local-first AI app.

---

## Subsequent Runs

After first-time setup is complete:

1. Open Xcode (or just double-click the built `.app` in `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/`)
2. Press **⌘R** — everything starts automatically

**You never need to start the backend manually.** It starts and stops with the app.

If you update Python dependencies:

```bash
cd backend
pip install -r requirements.txt   # installs into existing venv
```

Then do **⌘R** again — the build phase will re-sync the updated venv into the bundle.

---

## Verifying the Backend is Running

While the app is open, visit:

```
http://127.0.0.1:8765/docs
```

This opens the interactive FastAPI docs where you can inspect and test all API endpoints.

The sidebar in the app will also show an **"Backend offline"** warning in orange if the backend process failed to start.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Backend offline" banner in app | Check Xcode console for Python errors. Verify `backend/venv/` exists. |
| `python not found` at launch | Re-run `python3 -m venv venv && pip install -r requirements.txt` |
| Build script path error | Adjust the `${SRCROOT}` relative path in the Run Script build phase |
| FFmpeg not found during processing | Run `brew install ffmpeg`, then rebuild |
| Resemblyzer import error | `pip install resemblyzer` inside the venv |
| ElevenLabs 401 Unauthorized | Check `ELEVENLABS_API_KEY` in `backend/.env` |
| Ollama not responding | Run `ollama serve` in a terminal (Ollama must be running separately) |
