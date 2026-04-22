# Repository Guidelines

## Project Structure & Module Organization
The macOS SwiftUI client lives in `apps/macos/PersonalAIMeetingAssistant/`, organized by feature views in `Features/`, shared logic in `Services/`, and common models or view models alongside their consumers. Backend code resides in `backend/app/` with `api/`, `models/`, `schemas/`, `services/`, and `workers/` modules; reusable GPT prompts sit in `backend/prompts/`. Tests for the backend stay in `backend/tests/`, SwiftUI previews belong beside their feature views, and shared assets or docs live in `docs/`. Use `i ha` to bundle the Python runtime into the macOS app during Xcode builds.

## Build, Test, and Development Commands
Run `cd backend && python3 -m venv venv && pip install -r requirements.txt` to prepare the embedded backend environment. Launch the API locally with `cd backend && uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload` for debugging. Execute the backend test suite through `cd backend && pytest tests/ -v`, and lint Python code with `ruff check backend/` (add `--fix` when appropriate).

## Coding Style & Naming Conventions
Swift code uses four-space indentation, `PascalCase` for types (e.g., `MeetingDetailView`), and `camelCase` for properties or actions; group related view code with `// MARK:` comments. Python code follows Ruff’s 100-character limit, includes type hints, and is formatted by `ruff`. Organize providers under `backend/app/services/` using the existing factory pattern.

## Testing Guidelines
Mirror backend tests after their API namespace (`test_meetings.py` for `/meetings`). Use `pytest` with `TestClient` fixtures for HTTP flows and add database fixtures when touching persistence or workers. For Swift, supplement logic-heavy features with targeted XCTest cases or SwiftUI previews that exercise new states.

## Commit & Pull Request Guidelines
Write imperative, scope-prefixed commit messages such as `backend: add diarization retry logic` or `macos: polish meeting detail layout`. Keep the test suite green before opening a PR, include a concise summary with validation evidence (console output or screenshots), reference linked issues, and attach before/after captures for UI-facing changes.

## Security & Configuration Tips
Keep secrets in `.env` files ignored by Git; use `.env.example` as the configuration checklist. macOS app keys belong in the Keychain, while backend-only keys load from `.env` and are bundled automatically by `scripts/bundle_backend.sh`.


<claude-mem-context>
# Memory Context

# [KlarityApp] recent context, 2026-04-19 5:33pm GMT+5:30

No previous sessions found.
</claude-mem-context>