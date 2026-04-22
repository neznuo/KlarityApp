# Meeting Detection — Design

**Date:** 2026-04-22
**Status:** Approved

## Problem

Users must manually start recording before each meeting. Klarity has calendar integration and audio device monitoring, but neither is wired to detect meetings proactively and prompt the user to record.

## Decision

Add a `MeetingDetectorService` that combines calendar polling, audio device monitoring, and window title inspection to detect meetings in real-time and show an in-app notification under the menu bar icon prompting the user to start recording.

## Design

### MeetingDetectorService

A new `@MainActor` singleton service that runs always-on in the background, combining three detection signals:

1. **Calendar signal** — Polls `CalendarService.shared.fetchAllEvents()` every 5 minutes. When an event with `onlineMeetingUrl` is within the configured lead time (default 2 min) of starting, fires a detection event.

2. **Audio device signal** — Registers a Core Audio property listener on `kAudioHardwarePropertyDevices` (the global device list). When a new device appears, checks its name against known meeting app virtual devices. On match, fires a detection event.

3. **Window title signal** — Polls `NSWorkspace.shared.runningApplications` every 10 seconds. For each running app, uses the Accessibility API (`AXUIElementCopyAttributeValue` for `kAXTitleAttribute`) to read window titles. Matches against known patterns for FaceTime, WhatsApp, Google Meet, Zoom, Teams, Slack.

Publishes a single `@Published var detectedMeeting: DetectedMeeting?`. A `DetectedMeeting` has: `source` (calendar/audioDevice/windowTitle), `appName`, `meetingTitle`, and `onlineMeetingUrl` (from calendar, if available).

**Debouncing**: If a meeting is detected via multiple signals simultaneously (e.g., calendar + Zoom device), only one notification fires within a 30-second window.

### Notification UI

No system `UNUserNotificationCenter` notifications. The notification appears in-app, under the menu bar icon — same pattern as the existing recording reminder.

When `MeetingDetectorService` detects a meeting, the `MenuBarView` shows a dropdown notification with:
- Meeting app icon or generic meeting icon
- Title: "Meeting Starting — <app name>" or "Meeting Detected — <app name>"
- Subtitle: meeting title (from calendar or window title)
- "Start Recording" button

Clicking "Start Recording" starts recording via `startNewMeeting(calendarEventId:calendarSource:)` with the linked calendar event if available.

**No duplicate notifications**: The service tracks which meetings it has already notified about (by `calendarEventId` or composite key of `appName + timestamp`), so the same meeting doesn't trigger repeated banners.

**Permission**: Only Accessibility permission needed (for window title monitoring). Prompted from Settings with a clear explanation. Calendar signal works without it. If denied, window title detection is silently skipped.

### Settings

New "Meeting Detection" section in SettingsView:

- **Enable meeting detection** — Toggle (default: off). When enabled, starts the service. When disabled, stops all monitoring.
- **Detect calendar meetings** — Toggle (default: on, grayed out if no calendar connected). Controls calendar signal.
- **Detect audio/video calls** — Toggle (default: on). Controls audio device + window title signals. If Accessibility permission is not granted, shows a "Grant Access" link that opens System Settings.
- **Notify before meeting** — Picker: 1 min, 2 min, 5 min (default: 2 min). Only affects calendar signal.

No auto-record setting (notify-only behavior).

### Service Lifecycle

**Startup** (when enabled):
1. Start calendar polling timer (5 min interval)
2. Register Core Audio device list listener
3. Start window title polling timer (10 sec interval)
4. Immediate first check on all three signals

**Shutdown** (when disabled or app quits): Remove all timers and listeners. No lingering resources.

**Integration**: `MeetingDetectorService` is instantiated and held by `AppState` (the existing global environment object). `MenuBarView` reads `appState.meetingDetector.detectedMeeting`.

### Known Virtual Audio Devices

| Device name pattern | App |
|---|---|
| ZoomAudioDevice | Zoom |
| Microsoft Teams Audio | Microsoft Teams |
| Ecamm Live Audio | Ecamm Live |

FaceTime, WhatsApp, Google Meet, and Slack huddles do not create virtual audio devices — caught by window title signal.

### Known Window Title Patterns

| App | Window title pattern | Notes |
|---|---|---|
| FaceTime | contains "FaceTime" AND one of ("Call", "Audio", "Video") | |
| WhatsApp | contains "WhatsApp" AND one of ("Video", "Audio") | |
| Google Meet (Chrome) | matches regex `Meet - .+ - .+` | Chrome tab title format |
| Google Meet (Safari) | contains "meet.google.com" | Safari shows URL in title |
| Zoom | contains "Zoom Meeting" | Already covered by audio device, window title confirms |
| Teams | contains "Microsoft Teams" AND one of ("Call", "Meeting") | |
| Slack | contains "Slack" AND one of ("Huddle", "Call") | Slack huddles |

Both lists are stored as arrays of `MeetingSignalPattern` structs, easy to extend without code changes.

### Out of Scope

- Auto-start recording (notify-only for now)
- System (macOS) notifications — in-app only
- Detecting meetings in browser tabs without Accessibility permission
- Meeting end detection / auto-stop recording
- ScreenCaptureKit or browser extension approaches