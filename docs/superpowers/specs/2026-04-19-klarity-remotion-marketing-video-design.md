# Klarity Remotion Marketing Video Design

Date: 2026-04-19

## Goal

Create a 30-second, 16:9 marketing video for Klarity using Remotion. The video should feel like a premium product film while clearly demonstrating the core workflow: record a meeting locally, process it after the call, review speaker-labeled transcript content, and generate structured notes and tasks on demand.

## Audience

The primary viewer is an individual professional who spends time in meetings and wants reliable notes without adding a bot to calls. The video should work for a website hero, launch page, or product demo section.

## Positioning

Klarity is a local-first macOS meeting assistant that captures meetings without joining them as a bot. It turns recorded audio into transcripts, speaker identities, summaries, and tasks while keeping the user in control of storage and AI provider choices.

## Format

- Duration: 30 seconds
- Aspect ratio: 16:9
- Resolution: 1920x1080
- Frame rate: 30 fps
- Style: premium product film
- Audio: no required voiceover; the first implementation may be silent or use motion-only pacing
- Assets: use stylized app UI, typography, simple waveform and document visuals, and the existing Klarity logo where practical

## Storyboard

### 0-5s: Hook

Primary message: "From meeting to clarity, without a bot."

Open with a calm branded frame and a stylized macOS meeting context. The hook should establish the differentiator immediately: Klarity records locally instead of joining meetings as another participant.

### 5-11s: Recording

Show a polished recording scene with system audio and microphone capture represented as separate signal tracks that merge into one local recording. The motion should be smooth and deliberate, not frantic.

### 11-17s: Transcript

Transition into post-meeting processing. Transcript lines should appear with speaker labels and timestamps to show that Klarity produces reviewable meeting content after the recording ends.

### 17-23s: Speaker Identity

Show speaker suggestions and a clean review flow. The scene should communicate that Klarity can learn people over time while keeping the user in control of identity correction.

### 23-28s: Summary

Show structured outputs: decisions, action items, and concise meeting notes. The copy should imply that summaries are generated on demand, not automatically pushed without user intent.

### 28-30s: End Card

End with the Klarity logo and line: "Your private meeting memory."

## Visual Direction

Use a restrained, premium interface style:

- Dark neutral backgrounds balanced with light UI surfaces
- Crisp macOS-style panels
- Brand accents from the existing Klarity logo direction where practical
- No decorative clutter or excessive gradients
- Layouts should be stable and readable at 1920x1080

The video should be built from editable Remotion components rather than exported static mockups.

## Copy

Use concise product copy only:

- "From meeting to clarity, without a bot."
- "Capture system audio and mic locally."
- "Review a speaker-labeled transcript."
- "Confirm speakers as Klarity learns."
- "Generate decisions and tasks on demand."
- "Your private meeting memory."

## Implementation Requirements

- Add a Remotion project or video folder that can be run independently from the existing macOS/backend code.
- Define one renderable composition for the 30-second marketing video.
- Use reusable scene components and shared timing constants.
- Keep generated video code separate from existing app source unless a shared asset is intentionally reused.
- Avoid real user data, real meeting recordings, or secrets.

## Verification

At minimum:

- Install or use the local Remotion dependency setup.
- Run a Remotion still render check for the composition.
- Confirm the composition duration, resolution, and frame rate are correct.

If dependency installation or rendering is blocked by local environment constraints, report the exact blocker and leave the project files in a runnable state.

## Out of Scope

- Voiceover generation
- Licensed stock footage
- Real app screenshots
- Exporting a final MP4 unless explicitly requested after the composition is built
- Changes to the macOS app or backend behavior
