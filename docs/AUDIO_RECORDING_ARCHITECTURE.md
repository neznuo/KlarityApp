# Audio Recording Architecture — macOS Meeting Recorder

## Context

The current audio recording implementation is broken or unreliable. It fails to consistently capture a complete meeting — either the system audio is missing, the mic is missing, or the recording partially fails.

**This document defines the correct architecture. Refactor the audio recording module to match it exactly.**

---

## Target Architecture: Core Audio Taps + Aggregate Device → Single File

### Why the current approach fails

macOS does not allow capturing system audio via `AVAudioRecorder`, `AVCaptureSession`, or any standard AVFoundation API. Those APIs only access microphone input. Any approach relying on virtual drivers (BlackHole, Soundflower) is fragile and requires manual user setup.

### The correct approach (macOS 14.2+)

Use **Apple's Core Audio Taps API** (`AudioHardwareCreateProcessTap`), introduced in macOS 14.2 (December 2023). This is the only first-party, no-driver-install solution for capturing system audio output.

The key insight: **build a single aggregate device that combines the Core Audio Tap (system audio) AND the microphone input**. The IO callback then delivers both streams in one `AudioBufferList`, which you write directly to a single output file.

---

## Implementation Steps

### Step 1 — Create the process tap

```swift
import CoreAudio

// Tap all system audio output (stereo mixdown)
let tapDesc = CATapDescription(stereoMixdown: true)

// OR tap specific processes only (e.g. Zoom, Teams, Chrome):
// let tapDesc = CATapDescription(processes: [zoomPID, chromePID])

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
guard tapStatus == noErr else {
    // Handle error — tap creation failed
    return
}
```

### Step 2 — Get the microphone device UID

```swift
// Get the system default input device UID
var defaultInputDeviceID = AudioDeviceID(kAudioObjectUnknown)
var propertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject),
    &propertyAddress,
    0, nil,
    &dataSize,
    &defaultInputDeviceID
)

// Get its UID string
var micUID: CFString = "" as CFString
var uidAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var uidSize = UInt32(MemoryLayout<CFString>.size)
AudioObjectGetPropertyData(defaultInputDeviceID, &uidAddress, 0, nil, &uidSize, &micUID)
```

### Step 3 — Build the aggregate device with tap + mic

```swift
// CRITICAL: Include BOTH the tap AND the microphone sub-device
let aggregateProps: [String: Any] = [
    kAudioAggregateDeviceNameKey: "MeetingRecorderAggregateDevice",
    kAudioAggregateDeviceUIDKey: "com.yourapp.meetingrecorder.aggregate",
    kAudioAggregateDeviceIsPrivateKey: true,       // Don't show in System Settings
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: tapDesc.uuid.uuidString]
    ],
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: micUID as String]   // Include microphone
    ]
]

var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
let aggregateStatus = AudioHardwareCreateAggregateDevice(
    aggregateProps as CFDictionary,
    &aggregateDeviceID
)
guard aggregateStatus == noErr else {
    // Handle error — check if aggregate device already exists (OSStatus 1852797029)
    // If so, destroy existing one and retry
    return
}
```

> **Known issue:** If the app crashes mid-recording, the aggregate device may persist. On next launch, `AudioHardwareCreateAggregateDevice` returns `OSStatus 1852797029` ("already exists"). Always call cleanup on app launch and before creating a new device.

### Step 4 — Read the tap's audio format

```swift
// Get the audio format from the tap — use this for your AVAudioFile
var tapFormatAddress = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var tapASBD = AudioStreamBasicDescription()
var tapASBDSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(tapID, &tapFormatAddress, 0, nil, &tapASBDSize, &tapASBD)

let recordingFormat = AVAudioFormat(streamDescription: &tapASBD)!
```

### Step 5 — Create the output audio file

```swift
import AVFoundation

// Output as 16kHz mono WAV — optimal for ASR/transcription services
let outputSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 16000,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false
]

let outputURL = /* your temp file URL, e.g. in app's temp directory */
let audioFile = try AVAudioFile(
    forWriting: outputURL,
    settings: outputSettings,
    commonFormat: .pcmFormatInt16,
    interleaved: true
)
```

### Step 6 — Install IO proc and start recording

```swift
var ioProcID: AudioDeviceIOProcID?

AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) {
    inNow, inInputData, inInputTime, outOutputData, inOutputTime in

    // inInputData contains BOTH system audio and mic in the same AudioBufferList
    // Buffer layout: channel 0 = system audio, channel 1 = mic (or interleaved)

    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: recordingFormat,
        bufferListNoCopy: inInputData,
        deallocator: nil
    ) else { return }

    // Downsample and mix to mono if needed before writing
    // (use AVAudioConverter for sample rate conversion to 16kHz)
    try? audioFile.write(from: buffer)
}

// Start
AudioDeviceStart(aggregateDeviceID, ioProcID)
```

### Step 7 — Stop and clean up

```swift
func stopRecording() {
    AudioDeviceStop(aggregateDeviceID, ioProcID)
    AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
    AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    AudioHardwareDestroyProcessTap(tapID)
    // audioFile is finalized when it goes out of scope / is set to nil
}
```

---

## Sample Rate Conversion (Required for Transcription)

The system audio tap defaults to the device's native sample rate (44.1kHz or 48kHz, 32-bit float). Most ASR services (Whisper, Deepgram, AssemblyAI) work at 16kHz. Convert in Swift before writing — don't send raw 48kHz audio.

```swift
// Set up converter once, before recording starts
let inputFormat = recordingFormat  // from the tap (e.g. 48kHz stereo float32)
let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16000,
    channels: 1,
    interleaved: true
)!

let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!

// Inside IO proc — convert each buffer before writing
let frameCount = AVAudioFrameCount(
    Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
)
let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount)!
var error: NSError?
converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
    outStatus.pointee = .haveData
    return buffer
}
try? audioFile.write(from: convertedBuffer)
```

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

### Runtime permission check

```swift
// Check system audio permission before attempting to create tap
// If denied, AudioHardwareCreateProcessTap succeeds but delivers silence — no error thrown
// Use AudioCap's TCC probing approach to detect this:
// https://github.com/insidegui/AudioCap
```

> **Important:** If the user denies system audio capture permission, `AudioHardwareCreateProcessTap` will succeed but deliver silence — there is no error code. The app must proactively check and surface this to the user. The permission prompt appears on first tap creation.

---

## UX Notes

- macOS shows a **purple dot** in the menu bar when a Core Audio Tap is active (not the orange microphone blob from older approaches).
- Only requires `"System Audio Recording Only"` permission — NOT full `"Screen & System Audio Recording"`. This is less alarming to users.
- Does NOT require an app restart after permission is granted (unlike ScreenCaptureKit approaches).

---

## Output File

| Property | Value |
|---|---|
| Format | WAV (`.wav`) |
| Sample rate | 16,000 Hz |
| Channels | 1 (mono) |
| Bit depth | 16-bit PCM |
| Contents | System audio + microphone, mixed |

This single file is sent directly to the transcription service (Python backend). No merging step needed.

---

## Error Handling Checklist

| Scenario | Handling |
|---|---|
| Aggregate device already exists (`1852797029`) | Destroy existing device, retry |
| Tap permission denied (silent failure) | Proactively check TCC permission before starting |
| Device change mid-recording (e.g. headphones plugged in) | Listen for `kAudioHardwarePropertyDefaultOutputDevice` changes, restart tap |
| App crash without cleanup | Destroy aggregate device on next app launch before creating new one |

---

## Reference Implementations

Study these before implementing:

- **[insidegui/AudioCap](https://github.com/insidegui/AudioCap)** — The canonical Swift sample for Core Audio Taps. Includes TCC permission probing. Start here.
- **[RecapAI/Recap](https://github.com/RecapAI/Recap)** — Open-source AI meeting recorder using Core Audio Taps + mic + Whisper. Nearly identical use case.
- **[makeusabrew/audiotee](https://github.com/makeusabrew/audiotee)** — CLI tool that streams system audio to stdout. Study `Core/AudioTapManager` and `Core/AudioRecorder`.
- **[Apple Developer Docs — Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)**

---

## Minimum Deployment Target

**macOS 14.2 (Sonoma)** — `AudioHardwareCreateProcessTap` was introduced in 14.2.

If the user is on an older macOS, show an upgrade prompt. Do not attempt a fallback to BlackHole or virtual drivers — that adds user-facing complexity and is not worth supporting.

---

## What NOT to Use

| API | Why not |
|---|---|
| `AVAudioRecorder` | Microphone only — cannot capture system audio |
| `AVCaptureSession` | Microphone only — cannot capture system audio |
| BlackHole / Soundflower | Requires user to install a virtual driver and reconfigure system audio routing |
| ScreenCaptureKit audio loopback | Requires `"Screen & System Audio Recording"` permission (more invasive), triggers screen recording indicator, requires app restart after permission grant |
