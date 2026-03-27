@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.log

// MARK: - AudioRecorder
//
// Architecture: Core Audio Process Tap + Aggregate Device → single WAV file
//
// Why: SCStream in audio-only mode silently stops delivering audio after 2-5 min
// on macOS Sonoma/Sequoia (confirmed platform bug, no workaround). This implementation
// uses AudioHardwareCreateProcessTap (macOS 14.2+) which does not have this bug.
//
// Pipeline:
//   CATapDescription (all system audio, unmuted)
//     + mic sub-device
//     → aggregate device (IOProc delivers both in one AudioBufferList)
//     → AVAudioConverter (native rate/channels → 16kHz mono int16)
//     → AVAudioFile (WAV, written from a dedicated serial queue)
//
// Output: audio.wav — 16kHz mono 16-bit PCM, compatible with ElevenLabs Scribe.
// No post-recording merge or FFmpeg normalization step required.

@MainActor
final class AudioRecorder: NSObject, ObservableObject {

    enum RecordingState {
        case idle, preparing, recording, paused
    }

    @Published private(set) var state: RecordingState = .idle
    @Published var elapsedSeconds: Double = 0
    @Published var currentFilePath: URL?
    @Published var errorMessage: String?

    // Core Audio resources — only touched from the setup/teardown path
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // Audio conversion & writing
    private var inputFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var audioFile: AVAudioFile?
    // Serial queue: the IOProc runs on a Core Audio real-time thread; we dispatch
    // converted buffers here so disk I/O never blocks the real-time thread.
    private let writerQueue = DispatchQueue(label: "com.klarity.audioWriter", qos: .userInitiated)

    // State flags — accessed only from the main actor except `isPaused` which
    // is read from the IOProc (CoreAudio thread). Atomic read is safe for Bool.
    private var isPaused: Bool = false
    private var hasReceivedAudio: Bool = false
    private var controlState: RecordingState = .idle
    private var isPreparingCapture: Bool = false

    // Timer
    private var timer: Timer?
    private var recordingStart: Date?
    private var pauseAccumulated: Double = 0
    private var pauseStart: Date?

    private let logger = Logger(subsystem: "com.klarity.meeting-assistant", category: "AudioRecorder")

    // Fixed UID so we can find and destroy any leftover aggregate from a prior crash
    private let kAggregateUID = "com.klarity.meetingrecorder.aggregate.v2"

    // MARK: - Public API

    func startRecording(to audioURL: URL) {
        errorMessage = nil
        guard controlState == .idle, !isPreparingCapture else { return }

        state = .preparing
        isPreparingCapture = true
        currentFilePath = audioURL

        Task {
            do {
                try await self.setupAndStart(audioURL: audioURL)
                self.controlState = .recording
                self.isPreparingCapture = false
                self.state = .recording
                self.recordingStart = Date()
                self.startTimer()
                self.logger.info("Recording started → \(audioURL.lastPathComponent, privacy: .public)")
            } catch {
                self.logger.error("Recording setup failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                self.teardownCoreAudio()
                self.resetToIdle()
            }
        }
    }

    func pauseRecording() {
        guard controlState == .recording else { return }
        isPaused = true
        controlState = .paused
        state = .paused
        pauseStart = Date()
        stopTimer()
    }

    func resumeRecording() {
        guard controlState == .paused else { return }
        pauseAccumulated += Date().timeIntervalSince(pauseStart ?? Date())
        pauseStart = nil
        isPaused = false
        controlState = .recording
        state = .recording
        startTimer()
    }

    func stopRecording() async -> URL? {
        guard controlState == .recording || controlState == .paused else { return nil }

        let savedPath = currentFilePath
        stopTimer()
        controlState = .idle
        state = .idle
        isPreparingCapture = false
        isPaused = false
        elapsedSeconds = 0
        pauseAccumulated = 0

        // Stop Core Audio first (no more IOProc calls after this returns)
        teardownCoreAudio()

        // Drain the writer queue so all dispatched writes complete before we close the file
        await withCheckedContinuation { continuation in
            writerQueue.async { continuation.resume() }
        }
        audioFile = nil

        currentFilePath = nil

        guard hasReceivedAudio else {
            logger.error("Stopped with no audio data received — possible permission denial")
            errorMessage = "Recording failed: No audio was captured. Check System Settings → Privacy → Microphone and ensure system audio capture permission has been granted."
            if let p = savedPath { try? FileManager.default.removeItem(at: p) }
            return nil
        }

        hasReceivedAudio = false
        logger.info("Recording saved to: \(savedPath?.path ?? "nil", privacy: .public)")
        return savedPath
    }

    // MARK: - Setup

    private func setupAndStart(audioURL: URL) async throws {
        // Clean up any aggregate device left over from a previous crash
        destroyLeftoverAggregateDevice()

        // --- Step 1: Create process tap ---
        // CATapDescription(stereoGlobalTapButExcludeProcesses:[]) captures ALL system audio.
        // DO NOT use stereoMixdown: — that initializer does not exist in the shipping SDK.
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.muteBehavior = .unmuted  // capture without muting the output speakers

        var localTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &localTapID)
        guard tapStatus == noErr else {
            throw AudioRecorderError.tapCreationFailed(tapStatus)
        }
        tapID = localTapID
        logger.info("Process tap created: id=\(localTapID, privacy: .public)")

        // --- Step 2: Get device UIDs ---
        let outputUID = try defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let micUID    = try defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice)
        logger.info("Output UID: \(outputUID, privacy: .public)  Mic UID: \(micUID, privacy: .public)")

        // --- Step 3: Build aggregate device ---
        // The system output device is the clock master (kAudioAggregateDeviceMainSubDeviceKey).
        // The tap attaches to the output stream; the mic sub-device provides input channels.
        // kAudioSubTapDriftCompensationKey: true prevents drift between tap and mic over long recordings.
        let tapUID = tapDesc.uuid.uuidString   // .uuid is lowercase — SDK-verified
        let aggregateProps: [String: Any] = [
            kAudioAggregateDeviceNameKey:        "KlarityMeetingRecorder",
            kAudioAggregateDeviceUIDKey:         kAggregateUID,
            kAudioAggregateDeviceIsPrivateKey:   true,   // hidden from System Settings
            kAudioAggregateDeviceIsStackedKey:   false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey:               tapUID,
                 kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: micUID]
            ]
        ]

        var localAggID = AudioDeviceID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateProps as CFDictionary, &localAggID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw AudioRecorderError.aggregateDeviceCreationFailed(aggStatus)
        }
        aggregateDeviceID = localAggID
        logger.info("Aggregate device created: id=\(localAggID, privacy: .public)")

        // Give the HAL a moment to finish initialising the aggregate device
        // before we query its stream format (needed on some systems).
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms

        // --- Step 4: Read the aggregate device's input stream format ---
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope:    kAudioObjectPropertyScopeInput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(localAggID, &fmtAddr, 0, nil, &asbdSize, &asbd)
        guard fmtStatus == noErr, let inputFmt = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioRecorderError.formatQueryFailed(fmtStatus)
        }
        inputFormat = inputFmt
        logger.info("Aggregate input format: \(inputFmt, privacy: .public)")

        // --- Step 5: Set up converter → 16kHz mono int16 ---
        // This is the format ElevenLabs Scribe expects; no FFmpeg step needed.
        let outputFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate:   16_000,
            channels:     1,
            interleaved:  true
        )!
        guard let converter = AVAudioConverter(from: inputFmt, to: outputFmt) else {
            throw AudioRecorderError.converterCreationFailed(inputFmt, outputFmt)
        }
        audioConverter = converter

        // --- Step 6: Create WAV output file ---
        if FileManager.default.fileExists(atPath: audioURL.path) {
            try FileManager.default.removeItem(at: audioURL)
        }
        audioFile = try AVAudioFile(
            forWriting:   audioURL,
            settings:     outputFmt.settings,
            commonFormat: .pcmFormatInt16,
            interleaved:  true
        )

        // --- Step 7: Install IOProc ---
        var localProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&localProcID, localAggID, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleIOProc(inInputData: inInputData)
        }
        guard procStatus == noErr, let procID = localProcID else {
            throw AudioRecorderError.ioProcCreationFailed(procStatus)
        }
        ioProcID = procID

        // --- Step 8: Start ---
        let startStatus = AudioDeviceStart(localAggID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(localAggID, procID)
            ioProcID = nil
            throw AudioRecorderError.deviceStartFailed(startStatus)
        }
    }

    // MARK: - IOProc (called on Core Audio real-time thread)

    private func handleIOProc(inInputData: UnsafePointer<AudioBufferList>) {
        // isPaused is a plain Bool — one-word read is atomic on arm64/x86_64.
        guard !isPaused,
              let fmt       = inputFormat,
              let converter = audioConverter else { return }

        // bufferListNoCopy: the underlying memory is owned by Core Audio and valid only
        // for the duration of this callback. We must .copy() before dispatching async.
        guard let rawBuffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                               bufferListNoCopy: inInputData,
                                               deallocator: nil),
              let ownedBuffer = rawBuffer.copy() as? AVAudioPCMBuffer,
              ownedBuffer.frameLength > 0 else { return }

        hasReceivedAudio = true

        // Compute output frame count with a small headroom for rounding
        let ratio = converter.outputFormat.sampleRate / fmt.sampleRate
        let outCapacity = AVAudioFrameCount(Double(ownedBuffer.frameLength) * ratio) + 4
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                                      frameCapacity: outCapacity) else { return }

        var inputGiven = false
        var convertError: NSError?
        converter.convert(to: convertedBuffer, error: &convertError) { _, outStatus in
            if inputGiven {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputGiven = true
            return ownedBuffer
        }

        guard convertError == nil, convertedBuffer.frameLength > 0 else { return }

        // Capture reference so writerQueue.async doesn't extend self's lifetime unnecessarily
        let fileRef = audioFile
        writerQueue.async {
            try? fileRef?.write(from: convertedBuffer)
        }
    }

    // MARK: - Teardown

    private func teardownCoreAudio() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateDeviceID, proc)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        audioConverter = nil
        inputFormat = nil
    }

    // MARK: - Device UID helpers

    private func defaultDeviceUID(selector: AudioObjectPropertySelector) throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size, &deviceID)
        guard st == noErr else {
            throw AudioRecorderError.deviceLookupFailed(selector, st)
        }

        // Must use Unmanaged<CFString> — using CFString directly causes an unsafe
        // pointer warning and potential crash on some SDK versions.
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidSt = AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid)
        guard uidSt == noErr, let uid else {
            throw AudioRecorderError.deviceUIDFailed(deviceID, uidSt)
        }
        return uid.takeRetainedValue() as String
    }

    // MARK: - Leftover aggregate cleanup

    /// Finds and destroys any aggregate device left behind by a previous crash.
    /// Called at the start of every recording session.
    private func destroyLeftoverAggregateDevice() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &dataSize) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &dataSize, &devices) == noErr else { return }

        for deviceID in devices {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
                  let uid else { continue }
            if (uid.takeRetainedValue() as String) == kAggregateUID {
                logger.warning("Destroying leftover aggregate device from prior session: \(deviceID, privacy: .public)")
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    // MARK: - Helpers

    private func resetToIdle() {
        stopTimer()
        state = .idle
        controlState = .idle
        isPreparingCapture = false
        elapsedSeconds = 0
        pauseAccumulated = 0
        pauseStart = nil
        recordingStart = nil
        currentFilePath = nil
        isPaused = false
        hasReceivedAudio = false
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let start = self.recordingStart else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start) - self.pauseAccumulated
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var formattedElapsed: String {
        let total = Int(elapsedSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Errors

private enum AudioRecorderError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case formatQueryFailed(OSStatus)
    case converterCreationFailed(AVAudioFormat, AVAudioFormat)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case deviceLookupFailed(AudioObjectPropertySelector, OSStatus)
    case deviceUIDFailed(AudioDeviceID, OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):
            return "System audio tap creation failed (OSStatus \(s)). Ensure 'System Audio Recording' permission is granted in System Settings → Privacy."
        case .aggregateDeviceCreationFailed(let s):
            return "Aggregate audio device creation failed (OSStatus \(s))."
        case .formatQueryFailed(let s):
            return "Could not read aggregate device audio format (OSStatus \(s))."
        case .converterCreationFailed(let from, let to):
            return "Audio converter creation failed from \(from) to \(to)."
        case .ioProcCreationFailed(let s):
            return "Audio IOProc creation failed (OSStatus \(s))."
        case .deviceStartFailed(let s):
            return "Audio device start failed (OSStatus \(s))."
        case .deviceLookupFailed(let sel, let s):
            return "Device lookup failed for selector \(sel) (OSStatus \(s))."
        case .deviceUIDFailed(let id, let s):
            return "Device UID query failed for device \(id) (OSStatus \(s))."
        }
    }
}
