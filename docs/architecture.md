## Personal AI Meeting Assistant

Version: 1.0
Platform: macOS
Frontend: SwiftUI
Backend: Python FastAPI
Storage: Local filesystem + SQLite

---

## 1. Purpose

This document explains the technical architecture for the Personal AI Meeting Assistant so implementation agents such as Claude Code or Antigravity can build the system with the correct boundaries, workflows, and responsibilities.

This application is a **local-first personal desktop app** for recording meetings, transcribing them after the meeting ends, managing speaker identities, and generating AI summaries on demand.

The application **does not use a bot** to join meetings.

---

## 2. High-Level Architecture

```text
┌─────────────────────────────┐
│ SwiftUI macOS Desktop App   │
│ - Recording controls        │
│ - Meeting archive           │
│ - Transcript UI             │
│ - Speaker management        │
│ - Summary tab               │
│ - Settings                  │
└──────────────┬──────────────┘
               │ HTTP / Local API
               ▼
┌─────────────────────────────┐
│ Python FastAPI Backend      │
│ - Job orchestration         │
│ - Audio preprocessing       │
│ - Transcription providers   │
│ - Speaker embeddings        │
│ - Summary providers         │
│ - SQLite + file persistence │
└──────────────┬──────────────┘
               │
     ┌─────────┼─────────┐
     ▼         ▼         ▼
┌────────┐ ┌──────────┐ ┌────────────┐
│ FFmpeg │ │ ElevenLabs│ │ LLM Provider│
│ Audio  │ │ Scribe STT│ │ OpenAI /    │
│ tools  │ │           │ │ Anthropic / │
└────────┘ └──────────┘ │ Gemini /    │
                        │ Ollama      │
                        └────────────┘
```

---

## 3. Core Design Principles

### 3.1 Local-first

Recordings, transcripts, summaries, and speaker profiles should be stored locally by default.

### 3.2 Thin frontend

The SwiftUI app should focus on UX, state presentation, and recording control. Heavy AI and audio processing should live in Python.

### 3.3 Provider abstraction

Do not hardcode one transcription or one summary provider into business logic. Use interfaces or service abstractions.

### 3.4 User-controlled identity resolution

Speaker recognition should suggest, not silently override. Users must be able to fix identities from transcript and detected-people views.

### 3.5 Manual summary generation

Transcript generation can happen after recording automatically. Summary and task generation should happen only when the user clicks a button.

---

## 4. Runtime Components

### 4.1 SwiftUI macOS App

Responsibilities:

* start / pause / resume / stop recording
* create meeting records
* show meeting list and meeting detail pages
* render transcript tab
* render summary tab
* render bottom audio player
* allow speaker assignment, creation, and merges
* manage settings like API keys and storage directory
* call backend endpoints
* show processing states and errors

Should not:

* perform transcription
* run embeddings
* generate summaries
* manage heavy audio preprocessing

---

### 4.2 Python FastAPI Backend

Responsibilities:

* receive meeting processing requests
* normalize audio
* call transcription provider
* convert provider output into internal transcript schema
* generate speaker embeddings
* compare clusters to known people
* detect duplicate speakers
* persist transcript, people, summary, and task data
* call summary providers on demand
* export artifacts

Should not:

* own desktop UI logic
* directly control recording UI state

---

### 4.3 External and Pluggable Components

#### Audio preprocessing

* FFmpeg

#### Transcription

* Primary: ElevenLabs Scribe

#### Speaker embeddings

* Primary: Resemblyzer
* Future: pyannote embeddings

#### Summarization providers

* OpenAI
* Anthropic
* Gemini
* Ollama

---

## 5. Main User Workflow

```text
1. User opens app
2. User clicks Start Recording
3. SwiftUI app creates meeting record
4. SwiftUI app records system + mic audio
5. User stops recording
6. SwiftUI app saves audio file
7. SwiftUI app triggers backend processing
8. Backend preprocesses audio
9. Backend sends audio to transcription provider
10. Backend stores transcript + speaker clusters
11. App shows transcript and detected people
12. User fixes speaker identities if needed
13. User clicks "Generate Summary & Tasks"
14. Backend runs selected LLM provider
15. App displays summary in Summary tab
```

---

## 6. Processing Pipeline

### 6.1 Recording Phase

Owned by SwiftUI app.

Output:

* raw meeting audio file
* meeting metadata

### 6.2 Preprocessing Phase

Owned by backend.

Steps:

* validate source file
* normalize sample rate
* convert to mono if required
* optionally chunk long files
* create normalized audio artifact

Output:

* normalized audio file

### 6.3 Transcription Phase

Owned by backend.

Steps:

* select configured transcription provider
* upload normalized audio
* receive segmented transcript
* store raw provider JSON
* map response to internal schema

Output:

* transcript segments
* speaker clusters
* provider metadata

### 6.4 Speaker Matching Phase

Owned by backend.

Steps:

* extract representative audio for each speaker cluster
* compute embeddings
* compare to known people embeddings
* compare clusters within same meeting
* produce:

  * suggested known people matches
  * duplicate cluster suggestions

Output:

* suggested speaker assignments
* duplicate warnings

### 6.5 Review Phase

Owned by SwiftUI app with backend mutation endpoints.

User can:

* assign person
* create person
* merge speakers
* review audio snippets
* click transcript rows to seek audio

Output:

* corrected speaker mapping

### 6.6 Summary Phase

Owned by backend, triggered manually by UI.

Steps:

* collect current transcript with resolved speaker names
* apply summary prompt
* call selected LLM provider
* store JSON and Markdown outputs

Output:

* summary.json
* summary.md
* tasks.json

---

## 7. Meeting Detail Page Architecture

The meeting detail page should use a tabbed layout.

### Tabs

* Transcript
* Summary

### Persistent bottom region

* Audio player docked at bottom of page

### Transcript tab

Contains:

* participants or detected people sidebar/panel
* transcript list with timestamps
* inline actions:

  * assign person
  * create person
  * merge speaker
  * jump to audio

Behavior:

* clicking a transcript row seeks the audio player to that timestamp
* speaker edits update transcript labels immediately

### Summary tab

Contains:

* `Generate Summary & Tasks` button if summary does not exist
* summary sections if available
* re-generate action
* provider/model info used for current summary

### Bottom audio player

Contains:

* play/pause
* current time
* duration
* scrubber
* optional playback speed later

Important:

* same player remains visible while switching tabs
* player uses stored meeting recording file
* transcript clicks interact with this player

---

## 8. Data Model Boundaries

There are three separate identity concepts. Keep them separate.

### 8.1 Speaker Cluster

A temporary grouping detected in one meeting.

Example:

* Speaker_1
* Speaker_5

These are meeting-local.

### 8.2 Person Identity

A real-world person record in the app.

Example:

* Rahul
* Sarah
* John

### 8.3 Person Profile and Embeddings

Stored voice representation used for future matching.

Why this matters:
One real person may be split into multiple clusters in a single meeting. The app must support merging those clusters into one Person.

---

## 9. Storage Architecture

### 9.1 Filesystem Layout

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

### 9.2 Database

Use SQLite for local app state.

Recommended tables:

* meetings
* people
* person_embeddings
* speaker_clusters
* transcript_segments
* summaries
* tasks
* settings
* processing_jobs

---

## 10. API Boundary

The frontend should communicate with backend through a local HTTP API.

Reason:

* clean separation
* easier debugging
* easier backend testing
* future flexibility

Recommended endpoint groups:

* health
* meetings
* transcript
* people
* summaries
* settings
* exports

---

## 11. Error Handling Strategy

### Recording errors

Examples:

* missing microphone permission
* missing system audio route
* failed file write

UI behavior:

* show immediate error
* do not create corrupt meeting state if avoidable

### Processing errors

Examples:

* failed transcription API call
* invalid response
* audio preprocessing failure

Behavior:

* persist job status as failed
* allow retry
* preserve original audio file

### Summary errors

Examples:

* missing API key
* Ollama unavailable
* provider timeout

Behavior:

* keep transcript accessible
* summary tab shows actionable error and retry option

---

## 12. Security and Privacy

* Store API keys securely, ideally in macOS Keychain
* Keep meeting data local unless user explicitly configures cloud providers
* Do not silently upload data anywhere other than configured providers
* Do not auto-share or sync files
* Confirm destructive actions like deleting meetings or people

---

## 13. Extensibility Plan

The architecture should support future additions without major rewrites.

Possible future extensions:

* more transcription providers
* more summary templates
* PDF export
* local transcription
* calendar integration
* searchable embeddings / RAG over past meetings
* team features

To support this, use interfaces for:

* transcription providers
* summary providers
* export providers

---

## 14. Recommended Repo Layout

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
```

---

## 15. Build Order Recommendation

1. Project scaffolding
2. Meeting model + settings model
3. Recording flow
4. Backend preprocessing + transcription
5. Transcript UI
6. Speaker assignment + people library
7. Duplicate detection + merge flow
8. Audio player and transcript-to-audio seeking
9. Manual summary generation
10. Export and archive polish

---

## 16. Key Architectural Constraints

* No bot joins meetings
* No live transcription in V1
* Summary generation is manual
* Audio player must remain visible on meeting detail page
* Transcript rows must seek playback
* Speaker edits must be possible from transcript and detected-people views
* Frontend and backend concerns must remain separated

---

## 17. Definition of a Good V1

A good V1 is not the one with the most features.

A good V1 is one where:

* recording works reliably
* transcription works reliably
* speaker correction is practical
* clicking transcript rows makes audio verification easy
* summary generation is available on demand
* archive is usable
* the app feels stable and intentional

---

# End of Architecture.md
