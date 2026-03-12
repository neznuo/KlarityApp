
## Personal AI Meeting Assistant (SwiftUI + Python FastAPI)

Use this document as the implementation brief and execution plan for building a working V1 of a macOS desktop application called **Personal AI Meeting Assistant**.

Read the PRD carefully and implement the product in a structured, production-minded way. Do not optimize for flashy UI first. Optimize for a clean architecture, reliable local workflows, and a usable transcript correction flow.

---

## 1. Project Goal

Build a local-first macOS desktop application that:

* records meetings locally with **system audio + microphone**
* processes the recording **after the meeting ends**
* transcribes the meeting using **ElevenLabs Scribe** as the primary STT provider
* supports **LLM-based summarization** using cloud providers and **local Ollama**
* detects speakers and allows users to:

  * see all detected people
  * assign identities
  * create new people
  * merge duplicate speaker clusters
  * manage known voice profiles
* stores all recordings, transcripts, notes, summaries, and settings locally in a user-selected folder

The app must **not use a meeting bot**.

---

## 2. Implementation Priorities

Priority order:

1. Stable local recording workflow
2. Clear meeting/job lifecycle
3. Reliable transcription pipeline
4. Transcript viewer with speaker correction
5. Known people library and speaker matching
6. Manual summary generation
7. Settings and provider configuration
8. Export and archive polish

Do not overbuild features that are outside V1.

---

## 3. Tech Stack Requirements

### Frontend

* Swift
* SwiftUI
* macOS desktop app

### Backend

* Python 3.11+
* FastAPI
* Uvicorn

### Persistence

* SQLite
* Local filesystem

### Audio / Processing

* FFmpeg for preprocessing
* ElevenLabs Scribe for primary transcription
* Resemblyzer for voice embeddings and similarity matching
* Optional later: pyannote as an alternative

### LLM Providers

Implement a provider abstraction for:

* OpenAI
* Anthropic
* Gemini
* Ollama

---

## 4. Architecture Requirements

Use a two-part architecture:

```text
SwiftUI App
    ↕
Local FastAPI service
    ↓
Processing pipeline + local persistence
```

### SwiftUI app responsibilities

* record audio
* display meetings
* display transcript and summary
* allow user to edit speaker identities
* allow configuration of providers and storage paths
* trigger backend jobs
* render processing state
* host the persistent meeting audio player

### Python backend responsibilities

* preprocess audio
* call transcription provider
* normalize provider output into app schema
* generate and store speaker embeddings
* suggest known people and duplicate speakers
* generate summary and tasks
* persist structured outputs

Do not put heavy processing logic in the Swift layer.

---

## 5. Output Expectations

Generate a codebase scaffold with clear folder structure, working models, and implementation stubs where needed.

The result should include:

* SwiftUI app project structure
* Python backend project structure
* API contract between frontend and backend
* data models
* database schema or migration approach
* service abstractions
* example environment configuration
* sample prompts for summary generation
* placeholder UI states where needed

Where full implementation is too large in one pass, create a clean scaffold plus working vertical slices for the critical flows.

---

## 6. Required Folder Structure

Create a repo structure similar to this:

```text
personal-ai-meeting-assistant/
  README.md
  docs/
    prd-personal-ai-meeting-assistant.md
    build-plan-prompt.md
    architecture.md

  apps/
    macos/
      PersonalAIMeetingAssistant/
        App/
        Features/
          Home/
          Recording/
          MeetingDetail/
          Transcript/
          People/
          Settings/
        Models/
        Services/
        ViewModels/
        Resources/

  backend/
    app/
      api/
      core/
      db/
      models/
      schemas/
      services/
        audio/
        transcription/
        embeddings/
        summarization/
        storage/
      workers/
      prompts/
    tests/
    pyproject.toml
    requirements.txt

  storage/
    .gitkeep
```

You may adjust names slightly if needed, but keep the architecture clean and obvious.

---

## 7. Backend Domain Model Requirements

Implement app-level models for:

### Meeting

* id
* title
* started_at
* ended_at
* duration_seconds
* status
* audio_file_path
* normalized_audio_path
* transcript_json_path
* summary_json_path

### Person

* id
* display_name
* notes
* last_seen_at
* meeting_count
* created_at
* updated_at

### PersonEmbedding

* id
* person_id
* embedding_path or serialized vector
* source_meeting_id
* created_at

### SpeakerCluster

* id
* meeting_id
* temp_label
* assigned_person_id nullable
* confidence nullable
* duration_seconds
* segment_count
* duplicate_group_hint nullable

### TranscriptSegment

* id
* meeting_id
* cluster_id
* start_ms
* end_ms
* text
* confidence nullable
* audio_snippet_path nullable

### Summary

* id
* meeting_id
* provider
* model
* summary_markdown
* summary_json
* created_at

### Task

* id
* meeting_id
* owner_person_id nullable
* raw_owner_text nullable
* description
* due_date nullable
* status

### Setting

* key
* value

Use SQLAlchemy or SQLModel if that speeds up clean implementation.

---

## 8. API Endpoints Required

Design a practical local API.

At minimum implement endpoints for:

### Health / status

* `GET /health`
* `GET /settings`

### Meetings

* `GET /meetings`
* `POST /meetings`
* `GET /meetings/{meeting_id}`
* `DELETE /meetings/{meeting_id}`

### Recording / processing

* `POST /meetings/{meeting_id}/process`
* `POST /meetings/{meeting_id}/reprocess-summary`
* `POST /meetings/{meeting_id}/recompute-speaker-suggestions`

### Transcript

* `GET /meetings/{meeting_id}/transcript`
* `POST /meetings/{meeting_id}/assign-speaker`
* `POST /meetings/{meeting_id}/merge-speakers`

### People

* `GET /people`
* `POST /people`
* `PATCH /people/{person_id}`
* `DELETE /people/{person_id}`

### Summary / export

* `GET /meetings/{meeting_id}/summary`
* `POST /meetings/{meeting_id}/generate-summary`
* `POST /meetings/{meeting_id}/export`

### Settings

* `PATCH /settings`

Implement request/response schemas cleanly.

---

## 9. Recording Workflow Requirements

SwiftUI should implement a recording workflow with:

* Start Recording
* Pause Recording
* Resume Recording
* Stop Recording

Expected UX:

1. User clicks Start.
2. App creates meeting record immediately.
3. App starts local audio capture.
4. User stops recording.
5. App finalizes audio file.
6. App triggers backend processing.
7. Meeting status updates through states like:

   * recording
   * preprocessing
   * transcribing
   * matching_speakers
   * transcript_ready
   * summarizing
   * complete
   * failed

Add placeholder handling for permission errors and missing audio devices.

---

## 10. Speaker Workflow Requirements

This is critical. Build this carefully.

### Detected People panel

Show for each cluster:

* temporary label
* segment count
* speaking duration
* suggested known match with confidence
* possible duplicate warning
* transcript snippet preview
* audio preview action if available

### Transcript interactions

Each transcript segment should allow:

* Assign to existing person
* Create new person
* Merge into another speaker/person
* Jump meeting audio player to that timestamp

### Merge logic

When user merges:

* update all linked transcript segments
* update speaker cluster assignments
* keep the data model consistent
* prompt to regenerate summary if identities materially changed

Do not auto-merge in V1.

---

## 11. Known People Library Requirements

Create a dedicated People view that supports:

* list all known people
* show meeting count
* show last seen date
* rename person
* delete person

The assignment and creation flow should use this library consistently.

---

## 12. Summarization Requirements

Implement a summarization abstraction with provider implementations.

Providers:

* OpenAI
* Anthropic
* Gemini
* Ollama

Support model configuration via settings.

Generate both:

* `summary.md`
* `summary.json`

Required output sections:

* meeting_summary
* key_decisions
* action_items
* risks
* follow_up_email

The system prompt should explicitly avoid fabricating owners or due dates if not mentioned.

---

## 13. Settings Requirements

Implement a Settings screen and matching backend settings store for:

### Provider settings

* ElevenLabs API key
* OpenAI API key
* Anthropic API key
* Gemini API key
* Ollama endpoint
* default LLM provider
* default LLM model
* default transcription provider

### Storage settings

* base storage directory
* export directory if separate

### Matching settings

* known person suggestion threshold
* duplicate speaker threshold
* auto-assign threshold

Store secrets securely where possible. On macOS, prefer Keychain integration for secrets from the Swift app. If full secure secret integration is too large in one pass, scaffold it clearly and isolate secret handling behind a service layer.

---

## 14. Local File Layout Requirements

Use a predictable local file structure such as:

```text
<base_storage>/
  meetings/
    2026-03-10-product-sync/
      audio.wav
      normalized.wav
      transcript.raw.json
      transcript.json
      transcript.md
      summary.json
      summary.md
      tasks.json
  voices/
  exports/
  logs/
  app.db
```

The app should not hardcode a single path. Use configurable base storage.

---

## 15. Implementation Strategy

Build in phases inside the same repo:

### Phase 1

Create backend and frontend scaffolding:

* models
* API skeleton
* basic SwiftUI navigation
* settings storage
* meeting list

### Phase 2

Implement recording vertical slice:

* create meeting
* record audio
* stop and store file
* show status in UI

### Phase 3

Implement processing vertical slice:

* preprocess audio
* call ElevenLabs
* store normalized transcript output

### Phase 4

Implement transcript UI and speaker workflows:

* transcript list
* detected people panel
* assign speaker
* create person
* merge speakers
* clickable transcript to seek player

### Phase 5

Implement manual summary generation:

* provider abstraction
* OpenAI + Ollama first
* summary view in its own tab
* `Generate Summary & Tasks` button
* transcript can exist without summary

### Phase 6

Implement archive + export:

* search
* markdown export
* JSON export

Where helpful, include mock data for UI previews.

---

## 16. Coding Style Expectations

* Keep code modular.
* Prefer explicit interfaces for providers and services.
* Avoid giant files.
* Use typed schemas.
* Add docstrings and comments where useful.
* Keep naming consistent and boring rather than clever.
* Structure for maintainability.

---

## 17. Deliverables in First Pass

In the first full code generation pass, produce:

1. repository structure
2. backend app scaffold
3. frontend app scaffold
4. data models
5. main screens
6. API contracts
7. provider abstractions
8. placeholder implementations where needed
9. working path for at least:

   * create meeting
   * record placeholder or real file hook
   * process a stored audio file
   * show transcript
   * assign speaker
   * generate summary with one provider

If complete production implementation is too large, prioritize a real working vertical slice over broad fake completeness.

---

## 18. Important Constraints

* Do not introduce bot-based meeting attendance.
* Do not build live transcription for V1.
* Do not optimize for team collaboration.
* Do not make cloud dependency mandatory for summarization.
* Do not tightly couple the frontend to one provider.

---

## 19. Meeting Detail UX Requirements

The meeting detail page must use a tabbed layout.

Required tabs:

* Transcript
* Summary

### Transcript tab requirements

* Show the transcript list with timestamps.
* Each transcript segment must be clickable.
* Clicking a transcript segment must seek the meeting audio player to that point.
* Speaker correction actions should remain available from transcript rows.

### Summary tab requirements

* Summary generation is manual, not automatic.
* Show a `Generate Summary & Tasks` button when summary data does not yet exist.
* Allow the user to regenerate summary later.
* Display structured summary sections when available.

### Audio player requirements

* Place a persistent audio player at the bottom of the meeting detail page.
* The same player should remain available while switching between Transcript and Summary tabs.
* The player should use the stored meeting recording file.
* Include standard controls: play, pause, progress scrubber, current time, duration.

---

## 20. Important Workflow Constraint

Do not auto-generate summary and tasks immediately after transcription in V1.

The correct workflow is:

1. Record meeting
2. Process audio and generate transcript
3. Let user review / fix speakers if needed
4. User clicks `Generate Summary & Tasks`
5. App generates and stores summary outputs

---

## 21. Final Instruction

Build this as a pragmatic, local-first productivity app for one expert user. Favor clean architecture, a usable transcript correction flow, and provider flexibility over feature bloat.

Use the PRD as the source of truth. Where implementation details are ambiguous, make sensible product decisions and document them clearly in code comments or README notes.
