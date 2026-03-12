# Personal AI Meeting Assistant

## Product Requirements Document (PRD)

Version: 1.0
Platform: macOS
Frontend: SwiftUI
Backend: Python (FastAPI)
Primary User: Individual professional user

---

# 1. Product Vision

The Personal AI Meeting Assistant is a **local‑first macOS desktop application** that records meetings, transcribes them after the meeting ends, identifies speakers, and generates structured meeting notes.

Unlike traditional AI meeting assistants, the application **does not join meetings as a bot**. Instead, it records system audio and microphone input locally.

The system supports both **cloud AI providers and local AI models**, allowing the user to choose between privacy and convenience.

The application is designed to function as a **personal meeting intelligence system** that improves over time as it learns speaker identities.

---

# 2. Core Goals

Primary goals:

1. Capture meeting audio locally without bots
2. Produce highly accurate transcripts
3. Distinguish between multiple speakers
4. Learn and recognize known speakers over time
5. Allow manual correction and merging of speaker identities
6. Generate structured summaries and tasks using AI **on demand**
7. Allow configurable AI providers
8. Support local LLMs such as Ollama
9. Allow configurable storage locations
10. Provide a clean macOS‑native interface

---

# 3. Core Product Principles

### Local‑first

All recordings, transcripts, summaries, speaker embeddings, and meeting data should live locally by default.

### No meeting bots

The system must never require a bot to join Zoom, Meet, Teams, or any other meeting platform.

### Post‑meeting processing

Transcription and summarization happen **after recording**, improving accuracy and simplifying architecture.

### User‑controlled identity resolution

Speaker recognition should suggest identities but **never silently override the user**.

### Provider flexibility

Users should be able to switch between:

* cloud transcription
* local transcription (future)
* cloud LLM
* local LLM

without changing the product workflow.

---

# 4. System Architecture

The application consists of two primary components.

## 4.1 Frontend

SwiftUI macOS desktop application responsible for:

* meeting recording
* user interface
* meeting archive
* transcript view
* speaker management
* summary display
* configuration

## 4.2 Backend

Python service responsible for:

* audio preprocessing
* transcription
* speaker recognition
* summarization
* data persistence

## Architecture Diagram

```
SwiftUI Desktop App
        ↓
Local Python Service (FastAPI)
        ↓
Processing Pipeline
        ↓
Transcription Engine
        ↓
Speaker Recognition
        ↓
LLM Summary Generation
        ↓
Meeting Archive Storage
```

---

# 5. Core Features

---

# 5.1 Meeting Recording

The system must allow recording of meetings locally.

Recording must include:

* system audio
* microphone audio

Audio must be merged into a single recording.

Preferred format:

```
.wav
```

Audio normalization requirements:

```
16kHz
Mono
```

Recording controls:

* Start Recording
* Pause Recording
* Resume Recording
* Stop Recording

Metadata stored:

```
meeting_id
title
date
duration
audio_file_path
recording_status
```

Acceptance criteria:

* user can start recording
* user can stop recording
* audio file saved locally

---

# 5.2 Audio Preprocessing

After recording stops the backend must:

* normalize audio
* convert to mono
* resample to 16kHz
* optionally split long recordings

Recommended implementation:

```
FFmpeg
```

Output:

```
normalized_audio.wav
```

---

# 5.3 Transcription

The system transcribes audio after the meeting ends.

Primary provider:

```
ElevenLabs Scribe API
```

Future providers:

```
Whisper
AssemblyAI
Deepgram
```

Transcript output must include:

```
speaker_id
start_time
end_time
text
confidence
```

Example transcript:

```
Speaker_1: We should delay the launch.
Speaker_2: Marketing needs more time.
```

---

# 5.4 Speaker Diarization

Speakers are initially labeled as:

```
Speaker_1
Speaker_2
Speaker_3
```

Each speaker corresponds to a **speaker cluster**.

Cluster data includes:

```
segments
timestamps
embedding vector
speaking duration
```

---

# 5.5 Speaker Recognition

The system must support identifying speakers across meetings.

Voice embeddings generated using:

Preferred:

```
Resemblyzer
```

Alternative:

```
pyannote embeddings
```

Matching algorithm:

```
cosine similarity
```

Thresholds:

```
suggest match = 0.75
auto assign = 0.90
```

Voice profiles stored in:

```
/voices
```

Example:

```
rahul.embedding
sarah.embedding
john.embedding
```

---

# 5.6 Detected People Panel

The application must display detected speakers.

For each detected speaker:

Display:

```
cluster label
segment count
duration
suggested identity
confidence score
```

Example:

```
Speaker_1
Segments: 35
Duration: 15m
Suggested match: Rahul (91%)
```

User actions:

* assign identity
* merge speakers
* create person

---

# 5.7 Duplicate Speaker Detection

Sometimes one real person appears as multiple clusters.

Example:

```
Speaker_2
Speaker_5
```

System must detect duplicates using embedding similarity.

Example detection:

```
Speaker_2 and Speaker_5 similarity: 0.82
Possible duplicate
```

User can merge clusters.

---

# 5.8 Speaker Merge System

User must be able to merge speakers.

Example:

```
Merge Speaker_2 + Speaker_5 → Rahul
```

Effects:

* transcript labels updated
* speaker embeddings updated
* meeting participants updated

---

# 5.9 Transcript View Editing

Users must be able to edit speaker identity directly from transcript view.

Each transcript segment displays:

```
speaker
timestamp
text
actions
```

Actions:

```
Assign person
Create person
Merge speaker
Jump to audio
```

---

# 5.9A Clickable Transcript Audio Playback

The meeting page must include a **persistent audio player at the bottom**.

Transcript segments must be clickable.

Example:

```
00:12:43 Rahul: We should move launch to Friday.
```

When clicked:

* audio player seeks to 00:12:43
* playback starts

Player features:

* play
* pause
* scrub
* time display

---

# 5.10 Known People Library

The application maintains a library of known people.

Each record contains:

```
name
voice embeddings
meeting count
last seen date
notes
```

Example:

```
Rahul
Meetings: 12
Last seen: 2026‑03‑10
```

---

# 5.11 AI Summary Engine

Summary generation must be **manual**, not automatic.

User clicks:

```
Generate Summary & Tasks
```

Supported providers:

Cloud:

```
OpenAI
Anthropic
Gemini
```

Local:

```
Ollama
```

Configuration example:

```
Provider: Ollama
Model: llama3
Endpoint: http://localhost:11434
```

---

# 5.12 Summary Output Format

AI must generate:

```
Meeting Summary
Key Decisions
Action Items
Risks
Follow‑up Email Draft
```

Example:

Summary
Launch delayed by one week.

Decisions
Delay release until April 5.

Action Items
Rahul — update roadmap
Sarah — finalize campaign

---

# 5.13 Configurable Storage

User chooses base storage directory.

Default:

```
~/Documents/AI‑Meetings
```

Example meeting folder:

```
/Meetings
  /2026‑03‑10 Product Sync
    audio.wav
    transcript.json
    summary.md
    tasks.json
```

---

# 5.14 Meeting Archive

Each meeting contains:

```
title
date
duration
participants
transcript
summary
tasks
audio file
```

Search supports:

```
keyword
speaker
date
```

---

# 6. User Interface

Framework:

```
SwiftUI
```

## Home Screen

Features:

* Start Recording
* Recent Meetings
* Search Meetings

## Recording Screen

Displays:

* recording indicator
* timer

Controls:

* pause
* stop

---

## Meeting Detail Page

Tabbed layout:

Tabs:

```
Transcript
Summary
```

Persistent bottom area:

```
Audio player
```

### Transcript Tab

Contains transcript list.

Each row:

```
Speaker
Timestamp
Text
```

Click row → audio jumps to timestamp.

### Summary Tab

If summary not generated:

```
Button: Generate Summary & Tasks
```

If summary exists:

Display sections.

---

# 7. Data Storage

Local database:

```
SQLite
```

Tables:

```
meetings
people
speaker_clusters
transcript_segments
summaries
tasks
settings
```

---

# 8. Security

Sensitive data includes:

```
recordings
transcripts
API keys
voice embeddings
```

Requirements:

* API keys stored in macOS Keychain
* recordings stored locally
* cloud APIs used only when configured

---

# 9. Non Goals (V1)

Not included in V1:

```
live transcription
meeting bots
team collaboration
mobile apps
cloud sync
```

---

# 10. User Stories

## Record Meeting

As a user
I want to record meetings locally
So I can transcribe them later.

Acceptance:

* recording works
* audio file saved

---

## Generate Transcript

As a user
I want a transcript after recording
So I can review what was said.

Acceptance:

* transcript generated
* timestamps present

---

## Assign Speaker Identity

As a user
I want to name speakers
So transcripts show real participants.

Acceptance:

* assign names
* transcript updates

---

## Merge Duplicate Speakers

As a user
I want to merge duplicate speakers
So one person is not split across labels.

Acceptance:

* system suggests duplicates
* user merges clusters

---

## Generate Summary

As a user
I want AI summaries when I choose
So I control processing.

Acceptance:

* transcript exists without summary
* user clicks Generate Summary

---

## Click Transcript to Play Audio

As a user
I want transcript lines to jump to audio
So I can verify what was said.

Acceptance:

* clicking transcript seeks audio

---

# 11. MVP Definition

Version 1 includes:

```
meeting recording
audio preprocessing
ElevenLabs transcription
speaker tagging
speaker merge
known people library
manual summary generation
Ollama support
storage configuration
meeting archive
clickable transcript playback
markdown export
json export
```

---

# End of PRD
