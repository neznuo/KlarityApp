# Repository Guidelines

## Project Structure & Module Organization
- macOS SwiftUI client: `apps/macos/PersonalAIMeetingAssistant/` with feature views in `Features/`, shared logic in `Services/`, and co-located view models.
- Backend FastAPI app: `backend/app/` split into `api/`, `models/`, `schemas/`, `services/`, and `workers/`; shared GPT prompts live in `backend/prompts/`.
- Tests: backend coverage in `backend/tests/`; SwiftUI previews stay beside their views; shared docs and assets reside in `docs/`.
- Use `i ha` during Xcode builds to bundle the embedded Python runtime.

## Build, Test, and Development Commands
- `cd backend && python3 -m venv venv && pip install -r requirements.txt` prepares the backend virtual environment for local or bundled runs.
- `cd backend && uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload` starts the FastAPI server for iterative development.
- `cd backend && pytest tests/ -v` runs the backend test suite; `ruff check backend/ --fix` formats and lints Python modules.

## Coding Style & Naming Conventions
- Swift: four-space indentation, `PascalCase` types (e.g., `MeetingDetailView`), `camelCase` properties and actions, and `// MARK:` anchors to group related view logic.
- Python: adhere to Ruff’s 100-character limit, prefer explicit type hints, and organize service providers under the existing factory pattern in `backend/app/services/`.

## Testing Guidelines
- Mirror test modules to API namespaces (e.g., `/meetings` → `backend/tests/test_meetings.py`) and rely on `pytest` fixtures such as `TestClient` for HTTP flows.
- Add targeted database fixtures when workers or persistence code change; complement Swift logic with XCTest cases or previews covering new states.

## Commit & Pull Request Guidelines
- Craft imperative, scope-prefixed commits (e.g., `backend: add diarization retry logic`, `macos: polish meeting detail layout`).
- Open PRs only with a green test suite, concise summaries of changes, linked issues, and validation evidence (console output or UI screenshots for front-end updates).

## Security & Configuration Tips
- Keep secrets in `.env` files excluded from Git; maintain `.env.example` as the configuration contract.
- Store macOS app secrets in the Keychain and load backend-only keys from `.env` during bundling via `scripts/bundle_backend.sh`.
