# Audio Recording Architecture — macOS Meeting Recorder

## Context

The audio recording captures **system audio** (other participants, shared media) and **microphone** (the user's own voice) simultaneously, then mixes them into a single 16kHz mono WAV file for transcription.

The architecture uses **two independent capture paths** writing to separate temp files, then streaming-mixes them on stop. This design was reached after multiple days of debugging real failures (deadlocks, 2× speed playback, silent mic, crashes). Every rule in this document maps to at least one confirmed production failure.

---

## Two-Path Design

System audio and mic are captured on completely separate paths into separate temp WAV files. They **cannot** be combined into a single aggregate device because when the aggregate's main sub-device is an output device (required so the tap has a valid clock), macOS does **not** surface mic input buffers in the IOProc — mic buffers simply don't appear. Two paths is the only reliable solution.

Do **not** use `SCStream` (ScreenCaptureKit) for system audio. It silently stops delivering audio in audio-only mode after ~2–5 min on Sonoma/Sequoia. This is a confirmed platform bug with no workaround.

```
PATH 1 — System Audio
  CATapDescription(stereoGlobalTapButExcludeProcesses: [])
  → AudioHardwareCreateProcessTap()
  → Aggregate device (output UID + tap, no mic sub-device)
  → AudioDeviceCreateIOProcIDWithBlock  (real-time IOProc)
  → manual mono downmix of all tap channels (Float32)
  → AVAudioConverter: Float32 @ deviceSampleRate → Int16 @ 16kHz
  → audio_sys_tmp_{uuid}.wav

PATH 2 — Microphone
  AVAudioEngine.inputNode
  → installTap(onBus: 0, bufferSize: 4096, format: nil)
  → lazy AVAudioConverter created on FIRST callback using buffer.format
  → AVAudioConverter: hardware format → Int16 @ 16kHz
  → audio_mic_tmp_{uuid}.wav

POST-STOP — Streaming Mix
  Read both WAVs in 4096-frame chunks
  → float32 average sample-by-sample
  → AVAudioConverter: Float32 → Int16
  → audio.wav  (16kHz mono int16 PCM)
  Temp files deleted.
  If mic failed/empty → system audio copied directly as audio.wav.
```

---

## Exact Startup Order (non-negotiable — each step depends on the previous)

```
0. stopAllCapture()
      Full teardown of any previous recording state (tap, aggregate, engine,
      device listeners). Ensures clean state before starting. Prevents leftover
      resources from a crashed or incomplete prior recording from interfering.

1. destroyLeftoverAggregateDevice()
      Enumerate HAL devices by UID AND name, destroy any leftover aggregate from
      a prior crashed session. Creating a new aggregate with the same UID silently
      fails. Also destroys aggregates matching name "KlarityMeetingRecorder".

2. setupMicCapture()  ← AVAudioEngine starts HERE, before the aggregate is created
      a. Check mic permission inline (non-fatal — denied = skip mic, don't throw)
      b. Check default input device via kAudioHardwarePropertyDefaultInputDevice
         (NOT inputNode.inputFormat — returns 0Hz before start)
      c. engine = AVAudioEngine()
      d. let inputNode = engine.inputNode   ← MUST access on MainActor BEFORE start()
         (inputNode is lazy — not accessing it before start() → graph empty → crash)
      e. inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: ...)
         (nil format — let AVAudioEngine negotiate hardware format during start)
         (create AVAudioConverter lazily on first callback using buffer.format,
          which is always the true delivered format)
      f. engine.start() dispatched to DispatchQueue.global() — NOT MainActor
         (engine.start() calls prepare() which blocks on HAL callbacks;
          if called on MainActor it deadlocks waiting for callbacks that can't fire)

3. AudioHardwareCreateProcessTap(CATapDescription(stereoGlobalTapButExcludeProcesses: []))
      muteBehavior = .unmuted
      tapDesc.uuid.uuidString  ← lowercase .uuid, not .UUID

4. AudioHardwareCreateAggregateDevice(props)
      Required keys:
        kAudioAggregateDeviceNameKey:          "KlarityMeetingRecorder"
        kAudioAggregateDeviceUIDKey:           "com.klarity.meetingrecorder.aggregate.v2"
        kAudioAggregateDeviceIsPrivateKey:     true
        kAudioAggregateDeviceIsStackedKey:     false
        kAudioAggregateDeviceMainSubDeviceKey: outputUID
        kAudioAggregateDeviceTapListKey: [{kAudioSubTapUIDKey: tapUID,
                                           kAudioSubTapDriftCompensationKey: true}]
        kAudioAggregateDeviceSubDeviceListKey: [{kAudioSubDeviceUIDKey: outputUID}]
      NO mic sub-device — won't appear in IOProc anyway, just wastes resources

      RETRY: If creation fails, retry up to 3 times with 100ms delay.
      Transient failures are common after a previous recording's cleanup.

5. Task.sleep(150ms)  ← wait for HAL to settle after aggregate creation

6. Query kAudioDevicePropertyNominalSampleRate from aggregateDeviceID  ← CRITICAL
      NEVER query from the output device upfront.
      AVAudioEngine loads VPIO (Voice IO), which can change the output device's HAL
      sample rate between your upfront query and aggregate creation. The aggregate
      inherits the post-VPIO rate. Querying the aggregate AFTER creation + sleep gives
      the actual rate the IOProc will deliver. Using a stale pre-VPIO rate for the
      AVAudioConverter causes 2× speed playback.

      Console evidence VPIO is active: "Disabling HAL Voice Isolation support due to
      app's use of existing chat flavors"

      Also do NOT use:
        kAudioDevicePropertyStreamFormat (INPUT scope) → returns 2× real rate for tap aggregate
        kAudioTapPropertyFormat → also returns wrong/doubled value

7. Create AVAudioConverter(Float32 @ deviceSampleRate → Int16 @ 16_000)
8. Create AVAudioFile for audio_sys_tmp.wav
9. AudioDeviceCreateIOProcIDWithBlock + AudioDeviceStart
10. installDeviceChangeListeners()
      Register Core Audio property listeners for default output/input device changes.
      Changes during recording log a warning but don't restart capture.
```

---

## IOProc (system audio, real-time thread)

Receives `AudioBufferList` containing Float32 non-interleaved buffers. Manually downmixes all channels to mono Float32, wraps in `AVAudioPCMBuffer`, converts to Int16 @ 16kHz, writes to `audio_sys_tmp.wav` via a serial `DispatchQueue`.

**Thread safety:** `hasSysAudio` and `isPaused` are `OSAllocatedUnfairLock<Bool>` — accessed from both the IOProc real-time thread and MainActor. The lock provides the memory barrier needed for cross-thread visibility. Without it, MainActor could read stale `false` even though the IOProc had already set `true`, causing `stopRecording()` to discard captured audio.

---

## Post-Recording Mix

After both writer queues drain: reads both temp WAVs in 4096-frame Float32 chunks, averages sample-by-sample, converts to Int16, writes `audio.wav`. ~32KB working memory. If mic is empty, system audio is moved directly to `audio.wav`.

**Thread safety:** Before draining writer queues, `stopRecording()` stops the IOProc and mic tap. The drain ensures all pending writes complete. Then file handles are nil'd. This ordering guarantees no writes are lost.

---

## Output Format

`AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)`

Both temp files and final `audio.wav` use this format. **No AAC, no .caf, no Float32 WAV.**

---

## Reliability Safeguards

### Thread Safety

`hasSysAudio`, `hasMicAudio`, and `isPaused` use `OSAllocatedUnfairLock<Bool>`. These are accessed from both the real-time IOProc/mic-tap threads and MainActor. Bare `Bool` properties can produce stale reads across threads — the MainActor could read `false` even though the capture thread had already set `true`, causing `stopRecording()` to skip mixing or discard captured audio.

### Full Teardown Before Each Recording

`setupAndStart()` calls `stopAllCapture()` before creating any new resources. This prevents leftover state from a previous recording (or crashed session) from interfering. `destroyLeftoverAggregateDevice()` matches by both UID and name.

### Retry for Aggregate Device Creation

`AudioHardwareCreateAggregateDevice` is retried up to 3 times with 100ms delay. Transient failures are common after a previous recording's cleanup. Each retry first destroys any leftover aggregate.

### State Machine

Recording state transitions are enforced by `transition(to:)`:

```
Valid transitions:
  idle → preparing
  preparing → recording | idle (setup failed)
  recording → paused | idle (stop)
  paused → recording (resume) | idle (stop)
```

Invalid transitions log a warning. The single `@Published private(set) var state: RecordingState` is the source of truth — no separate `controlState` or `isPreparingCapture`.

### Health Check Timer

3 seconds after recording starts, checks whether `hasSysAudio` and `hasMicAudio` are true. If not, logs diagnostic warnings (doesn't stop recording — just informs the user).

A 10-second periodic stall detector warns if system audio stops flowing during an active recording. This catches cases where the audio device changed or the tap stopped delivering data.

### Audio Device Change Detection

Core Audio property listeners for `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDefaultInputDevice` are registered during recording. Changes (headphones unplugged, Bluetooth disconnected) log a prominent warning. No automatic restart — that's a future iteration.

### App Lifecycle Cleanup

`AudioRecorder.cleanup()` is called from `NSApplication.willTerminateNotification` to release Core Audio taps and aggregate devices even if the app is killed mid-recording. Without this, a force-quit would leak the aggregate device and process tap.

---

## Error Handling Checklist

| Scenario | Handling |
|---|---|
| Aggregate device already exists (`1852797029`) | `destroyLeftoverAggregateDevice()` runs at start; retries creation up to 3 times |
| Tap permission denied (silent failure) | Health check timer after 3s logs warning; `stopRecording()` checks `hasSysAudio` flag |
| Mic permission denied | Non-fatal — recording continues with system audio only |
| Device change mid-recording | Core Audio property listener logs warning; recording continues with current device |
| App crash without cleanup | Aggregate device/tap persist; `destroyLeftoverAggregateDevice()` cleans up on next launch; `cleanup()` called on app termination |
| VPIO sample rate change | Sample rate queried from aggregate device after creation + 150ms sleep, not from output device |
| No default input device | Mic setup skipped; recording continues with system audio only |
| AVAudioEngine start deadlock | `engine.start()` runs on `DispatchQueue.global()`, not MainActor |

---

## What NOT to Use

| API | Why not |
|---|---|
| `AVAudioRecorder` | Microphone only — cannot capture system audio |
| `AVCaptureSession` | Microphone only — cannot capture system audio |
| BlackHole / Soundflower | Requires user to install a virtual driver and reconfigure system audio routing |
| ScreenCaptureKit audio loopback | Requires `"Screen & System Audio Recording"` permission (more invasive), triggers screen recording indicator, requires app restart after permission grant, silently stops delivering audio after ~2–5 min in audio-only mode |
| Single aggregate device with mic | When aggregate's main sub-device is an output device (required for tap clock), macOS does not surface mic input in IOProc — mic buffers are empty |
| `kAudioDevicePropertyStreamFormat` (INPUT scope) | Returns 2× real rate for tap aggregate |
| `kAudioTapPropertyFormat` | Also returns wrong/doubled value |
| `inputNode.inputFormat(forBus: 0)` before `engine.start()` | Returns 0Hz — must use `buffer.format` from first callback instead |

---

## Permissions

### Info.plist entries (both required)

```xml
<!-- Microphone access -->
<key>NSMicrophoneUsageDescription</key>
<string>Required to record your voice during meetings</string>

<!-- System audio capture via Core Audio Tap -->
<!-- NOTE: This key does NOT appear in Xcode's dropdown — type it manually -->
<key>NSAudioCaptureUsageDescription</key>
<string>Required to capture meeting participants' audio</string>
```

### Entitlements file

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

### Runtime permission behavior

If the user denies system audio capture permission, `AudioHardwareCreateProcessTap` will succeed but deliver silence — there is no error code. The health check timer (3 seconds after start) detects this and logs a warning. The `hasSysAudio` flag in `stopRecording()` produces a user-facing error message directing them to System Settings.

---

## Minimum Deployment Target

**macOS 14.2 (Sonoma)** — `AudioHardwareCreateProcessTap` was introduced in 14.2.

If the user is on an older macOS, show an upgrade prompt. Do not attempt a fallback to BlackHole or virtual drivers — that adds user-facing complexity and is not worth supporting.

---

## Reference Implementations

- **[insidegui/AudioCap](https://github.com/insidegui/AudioCap)** — The canonical Swift sample for Core Audio Taps. Includes TCC permission probing. Start here.
- **Apple Developer Docs — Capturing system audio with Core Audio taps**