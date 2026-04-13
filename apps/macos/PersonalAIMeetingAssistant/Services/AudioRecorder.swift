@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.lock

// MARK: - AudioRecorder
//
// Architecture: two independent capture paths → two temp WAV files → streamed mix → audio.wav
//
//   PATH 1 — System audio:
//     CATapDescription (all output, unmuted)
//     → aggregate device (output device + tap)
//     → IOProc → manual mono mix → 16kHz int16 → audio_sys_tmp.wav
//
//   PATH 2 — Microphone:
//     AVAudioEngine.inputNode tap
//     → AVAudioConverter → 16kHz int16 → audio_mic_tmp.wav
//
//   POST-STOP — Streaming mix (no FFmpeg needed):
//     chunk-by-chunk float32 average of both WAV files → audio.wav
//     temp files deleted
//
// Why two paths instead of a single aggregate?
// When the aggregate device's main sub-device is an output device (required so the tap
// has a valid clock), macOS does not surface mic input buffers in the IOProc's inInputData.
// The tap is the only input delivered. Attempting to include the mic as a sub-device in
// the same aggregate consistently produces silence for the mic track.
// Two separate capture paths is the proven, reliable solution.

@MainActor
final class AudioRecorder: NSObject, ObservableObject {

    enum RecordingState {
        case idle, preparing, recording, paused
    }

    @Published private(set) var state: RecordingState = .idle
    @Published var elapsedSeconds: Double = 0
    @Published var currentFilePath: URL?
    @Published var errorMessage: String?

    // Audio source status — observable by views. Set from MainActor.
    // These mirror the lock-protected hasSysAudioLock/hasMicAudioLock for SwiftUI binding.
    @Published private(set) var hasSysAudioSource: Bool = false
    @Published private(set) var hasMicAudioSource: Bool = false

    // MARK: System audio (Core Audio Tap)

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var deviceSampleRate: Double = 48000.0
    private var monoInputFormat: AVAudioFormat?
    private var tapConverter: AVAudioConverter?
    private var sysAudioFile: AVAudioFile?
    private var sysTempURL: URL?
    private let sysWriterQueue = DispatchQueue(label: "com.klarity.sysWriter", qos: .userInitiated)

    // MARK: Microphone (AVAudioEngine)

    private var audioEngine: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private var micAudioFile: AVAudioFile?
    private var micTempURL: URL?
    private let micWriterQueue = DispatchQueue(label: "com.klarity.micWriter", qos: .userInitiated)
    // Thread-safe wrapper for micConverter — accessed from both the AVAudioEngine tap
    // callback (audio thread) and MainActor (setup/teardown).
    private let micConverterLock = OSAllocatedUnfairLock<AVAudioConverter?>(initialState: nil)

    // MARK: Shared state (thread-safe)

    // These are accessed from both real-time IOProc/mic-tap threads and MainActor.
    // OSAllocatedUnfairLock provides the memory barrier needed for cross-thread visibility.
    private let hasSysAudioLock = OSAllocatedUnfairLock(initialState: false)
    private let hasMicAudioLock = OSAllocatedUnfairLock(initialState: false)
    private let isPausedLock = OSAllocatedUnfairLock(initialState: false)

    // MARK: Timers

    private var timer: Timer?
    private var recordingStart: Date?
    private var pauseAccumulated: Double = 0
    private var pauseStart: Date?
    private var healthCheckTimer: Timer?
    private var stallCheckTimer: Timer?

    // MARK: Audio device change listener

    private var outputDeviceChangeListenerInstalled = false
    private var inputDeviceChangeListenerInstalled = false

    private let logger = AppLogger(category: "AudioRecorder")
    private let kAggregateUID = "com.klarity.meetingrecorder.aggregate.v2"
    private let kAggregateName = "KlarityMeetingRecorder"

    // MARK: - State machine

    /// Enforces valid state transitions. Logs warnings for invalid transitions.
    private func transition(to newState: RecordingState) {
        let from = state
        let valid: Bool
        switch (from, newState) {
        case (.idle, .preparing):      valid = true
        case (.preparing, .recording): valid = true
        case (.preparing, .idle):      valid = true  // setup failed
        case (.recording, .paused):    valid = true
        case (.recording, .idle):      valid = true  // stop
        case (.paused, .recording):    valid = true   // resume
        case (.paused, .idle):         valid = true   // stop
        default:                       valid = false
        }
        if !valid {
            logger.warn("Invalid state transition: \(from) → \(newState)")
        }
        state = newState
    }

    // MARK: - Public API

    func startRecording(to audioURL: URL) {
        errorMessage = nil
        guard state == .idle else {
            logger.warn("startRecording called in state \(state) — ignoring")
            return
        }

        guard #available(macOS 14.2, *) else {
            errorMessage = "Meeting recording requires macOS 14.2 (Sonoma) or later."
            return
        }

        transition(to: .preparing)
        currentFilePath = audioURL

        Task {
            do {
                try await self.setupAndStart(audioURL: audioURL)
                self.transition(to: .recording)
                self.recordingStart = Date()
                self.startTimer()
                self.scheduleHealthCheck()
                self.logger.info("Recording started → \(audioURL.lastPathComponent)")
            } catch {
                self.logger.error("Recording setup failed: \(error.localizedDescription)")
                self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                self.teardownAll()
                self.resetToIdle()
            }
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        isPausedLock.withLock { $0 = true }
        transition(to: .paused)
        pauseStart = Date()
        stopTimer()
    }

    func resumeRecording() {
        guard state == .paused else { return }
        pauseAccumulated += Date().timeIntervalSince(pauseStart ?? Date())
        pauseStart = nil
        isPausedLock.withLock { $0 = false }
        transition(to: .recording)
        startTimer()
    }

    func stopRecording() async -> URL? {
        guard state == .recording || state == .paused else { return nil }

        let savedPath = currentFilePath
        stopTimer()
        cancelHealthCheck()
        transition(to: .idle)
        isPausedLock.withLock { $0 = false }
        elapsedSeconds = 0
        pauseAccumulated = 0

        // 1. Stop both capture paths and device listeners
        stopAllCapture()

        // 2. Drain both writer queues so all pending writes complete
        await withCheckedContinuation { continuation in
            sysWriterQueue.async { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            micWriterQueue.async { continuation.resume() }
        }

        // 3. Close file handles
        let sysTmp = sysTempURL
        let micTmp = micTempURL
        sysAudioFile = nil
        micAudioFile = nil
        sysTempURL = nil
        micTempURL = nil
        currentFilePath = nil

        let hasSys = hasSysAudioLock.withLock { $0 }
        let hasMic = hasMicAudioLock.withLock { $0 }

        guard hasSys, let sysURL = sysTmp, let outputURL = savedPath else {
            logger.error("No system audio received — possible permission denial or tap failure")
            errorMessage = "Recording failed: No audio captured. Grant 'System Audio Recording' permission in System Settings → Privacy, then try again."
            sysTmp.flatMap { try? FileManager.default.removeItem(at: $0) }
            micTmp.flatMap { try? FileManager.default.removeItem(at: $0) }
            return nil
        }

        // 4. Mix system audio + mic into the final output file
        if hasMic, let micURL = micTmp {
            logger.info("Mixing system audio + mic → \(outputURL.lastPathComponent)")
            do {
                try await mixStreaming(sysURL: sysURL, micURL: micURL, outputURL: outputURL)
            } catch {
                logger.error("Mix failed (\(error.localizedDescription)) — using system audio only")
                moveFile(from: sysURL, to: outputURL)
                try? FileManager.default.removeItem(at: micURL)
            }
        } else {
            logger.info("No mic audio — using system audio only")
            moveFile(from: sysURL, to: outputURL)
            if let m = micTmp { try? FileManager.default.removeItem(at: m) }
        }

        hasSysAudioLock.withLock { $0 = false }
        hasMicAudioLock.withLock { $0 = false }
        hasSysAudioSource = false
        hasMicAudioSource = false
        logger.info("Recording saved: \(outputURL.path)")
        return outputURL
    }

    /// Clean up all resources. Called from app termination handler.
    /// Safe to call multiple times and from any state.
    @MainActor
    func cleanup() {
        teardownAll()
        resetToIdle()
    }

    // MARK: - Setup

    @available(macOS 14.2, *)
    private func setupAndStart(audioURL: URL) async throws {
        // Full teardown of any previous recording state before starting fresh.
        // This handles the case where a previous recording's cleanup was incomplete
        // (e.g., app crash, interrupted stop).
        stopAllCapture()

        destroyLeftoverAggregateDevice()

        // Temp file paths for two separate streams
        let dir  = audioURL.deletingLastPathComponent()
        let uuid = UUID().uuidString
        let sysURL = dir.appendingPathComponent("audio_sys_tmp_\(uuid).wav")
        let micURL = dir.appendingPathComponent("audio_mic_tmp_\(uuid).wav")
        sysTempURL = sysURL
        micTempURL = micURL

        // Target format shared by both capture paths: 16kHz mono int16 PCM
        let pcm16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

        let outputUID = try defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        logger.info("Output UID: \(outputUID)")

        // ── PATH 2: AVAudioEngine → microphone ────────────────────────────
        // MUST start before creating the Core Audio aggregate device.
        // AudioHardwareCreateAggregateDevice triggers a HAL reconfiguration; calling
        // engine.start() (which calls prepare() internally) afterwards can deadlock.
        // Non-throwing: mic failure skips mic capture but never aborts recording.
        await setupMicCapture(outputURL: micURL, outputFormat: pcm16)

        // ── PATH 1: Core Audio Tap → system audio ──────────────────────────

        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.muteBehavior = .unmuted

        var localTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &localTapID)
        guard tapStatus == noErr else { throw AudioRecorderError.tapCreationFailed(tapStatus) }
        tapID = localTapID

        // Aggregate device: output device + tap only (no mic sub-device).
        // Adding a mic sub-device here doesn't surface mic data in the IOProc when
        // the clock master is an output-only device — mic is captured separately via AVAudioEngine.
        let tapUID = tapDesc.uuid.uuidString

        // Retry aggregate device creation — transient failures are common after cleanup.
        let aggregateProps: [String: Any] = [
            kAudioAggregateDeviceNameKey:          kAggregateName,
            kAudioAggregateDeviceUIDKey:           kAggregateUID,
            kAudioAggregateDeviceIsPrivateKey:     true,
            kAudioAggregateDeviceIsStackedKey:     false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ]
        ]

        var localAggID = AudioDeviceID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateProps as CFDictionary, &localAggID)
        if aggStatus != noErr {
            // Retry up to 3 times with a short delay
            var lastStatus = aggStatus
            for attempt in 1...3 {
                logger.warn("Aggregate device creation failed (OSStatus \(lastStatus)), retry \(attempt)/3")
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                // Destroy any leftover aggregate that might be blocking creation
                destroyLeftoverAggregateDevice()
                let retryStatus = AudioHardwareCreateAggregateDevice(aggregateProps as CFDictionary, &localAggID)
                if retryStatus == noErr {
                    lastStatus = noErr
                    break
                }
                lastStatus = retryStatus
            }
            if lastStatus != noErr {
                AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown)
                throw AudioRecorderError.aggregateDeviceCreationFailed(lastStatus)
            }
        }
        aggregateDeviceID = localAggID

        try await Task.sleep(nanoseconds: 150_000_000) // 150ms for HAL to stabilise

        // Query the nominal sample rate from the aggregate device AFTER it has settled.
        // This is the authoritative rate for what the IOProc will deliver.
        // Must be done AFTER AVAudioEngine starts (above) because AVAudioEngine loads VPIO,
        // which can force-change the output device's HAL sample rate before aggregate creation.
        // Querying upfront (before engine start) may capture the pre-VPIO rate, causing a
        // mismatch between the converter's input format and the actual IOProc buffer rate →
        // audio plays back at 2× speed.
        var aggrSrAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var aggrSr: Float64 = 0
        var aggrSrSize = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(localAggID, &aggrSrAddr, 0, nil, &aggrSrSize, &aggrSr) == noErr, aggrSr > 0 {
            deviceSampleRate = aggrSr
        }
        logger.info("Aggregate device sample rate: \(self.deviceSampleRate) Hz")

        // Converter: mono float32 @ device rate → mono int16 @ 16kHz
        let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: deviceSampleRate, channels: 1, interleaved: true)!
        monoInputFormat = monoFmt
        guard let conv = AVAudioConverter(from: monoFmt, to: pcm16) else {
            throw AudioRecorderError.converterCreationFailed(monoFmt, pcm16)
        }
        tapConverter = conv

        // System audio temp WAV
        sysAudioFile = try AVAudioFile(forWriting: sysURL, settings: pcm16.settings,
                                        commonFormat: .pcmFormatInt16, interleaved: true)

        // IOProc
        var localProcID: AudioDeviceIOProcID?
        let procSt = AudioDeviceCreateIOProcIDWithBlock(&localProcID, localAggID, nil,
            { [weak self] _, inInputData, _, _, _ in
            self?.handleTapIOProc(inInputData: inInputData)
        })
        guard procSt == noErr, let procID = localProcID else { throw AudioRecorderError.ioProcCreationFailed(procSt) }
        ioProcID = procID

        let startSt = AudioDeviceStart(localAggID, procID)
        guard startSt == noErr else {
            AudioDeviceDestroyIOProcID(localAggID, procID); ioProcID = nil
            throw AudioRecorderError.deviceStartFailed(startSt)
        }

        // Register device change listeners
        installDeviceChangeListeners()
    }

    // Non-throwing: any failure just skips mic capture. Recording always continues with system audio.
    private func setupMicCapture(outputURL: URL, outputFormat: AVAudioFormat) async {
        // Request mic permission if needed. Denied → skip mic, not a recording failure.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            guard granted else {
                logger.info("Mic permission denied — recording system audio only")
                return
            }
        } else if status == .denied || status == .restricted {
            logger.info("Mic permission not granted — recording system audio only")
            return
        }

        // Confirm a default input device exists via CoreAudio.
        // We don't use inputNode.inputFormat() here — it returns 0Hz before engine start.
        var inputDevID = AudioDeviceID(kAudioObjectUnknown)
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var inputSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &inputAddr, 0, nil, &inputSize, &inputDevID)
        guard inputDevID != AudioDeviceID(kAudioObjectUnknown) else {
            logger.info("No default input device — recording system audio only")
            return
        }

        guard let file = try? AVAudioFile(forWriting: outputURL, settings: outputFormat.settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true) else {
            logger.error("Could not create mic output file — recording system audio only")
            return
        }
        micAudioFile = file

        let engine = AVAudioEngine()

        // CRITICAL: access inputNode on MainActor BEFORE start() — it is lazily created.
        // Calling start() first leaves the engine graph empty → "inputNode != nullptr" crash.
        let inputNode = engine.inputNode

        // Use the input node's reported output format as the tap format.
        // Specifying an explicit format (instead of nil) ensures the tap delivers buffers in a
        // known format that AVAudioConverter can always handle. With format: nil, the tap
        // may deliver non-interleaved multi-channel Float32 that AVAudioConverter silently
        // refuses to convert to interleaved Int16, causing ALL mic buffers to be dropped.
        // After engine.start(), inputNode.outputFormat(forBus:0) returns the true hardware
        // format. Before start, it may return 0Hz — so we fall back to a safe default.
        var tapFormat = inputNode.outputFormat(forBus: 0)
        if tapFormat.sampleRate == 0 || tapFormat.channelCount == 0 {
            // Engine not yet started — use a safe default. The engine will renegotiate
            // the actual hardware format during start(), and the tap adapts automatically.
            tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        }
        logger.info("Mic tap format: \(tapFormat.commonFormat.rawValue), \(tapFormat.sampleRate)Hz, \(tapFormat.channelCount)ch, interleaved=\(tapFormat.isInterleaved)")

        // Create the converter upfront using the known tap format, before the tap fires.
        // This avoids the silent-failure path where lazy converter creation returns nil
        // and every buffer is dropped for the entire recording.
        guard let preConverter = AVAudioConverter(from: tapFormat, to: outputFormat) else {
            logger.error("Cannot create mic converter (\(tapFormat.commonFormat.rawValue) \(tapFormat.sampleRate)Hz \(tapFormat.channelCount)ch → \(outputFormat.commonFormat.rawValue) \(outputFormat.sampleRate)Hz \(outputFormat.channelCount)ch) — recording system audio only")
            micAudioFile = nil
            return
        }
        micConverterLock.withLock { $0 = preConverter }
        micConverter = preConverter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat, block: { [weak self] buffer, _ in
            guard let self else { return }
            let paused = self.isPausedLock.withLock { $0 }
            guard !paused, buffer.frameLength > 0 else { return }

            let converter = self.micConverterLock.withLock { $0 }
            guard let converter else { return }

            let ratio  = outputFormat.sampleRate / buffer.format.sampleRate
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCap) else { return }

            var error: NSError?
            var inputUsed = false
            converter.convert(to: outBuf, error: &error) { _, status in
                if inputUsed { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData; inputUsed = true
                return buffer
            }
            if let convertError = error {
                self.logger.error("Mic converter error: \(convertError.localizedDescription)")
                return
            }
            guard outBuf.frameLength > 0 else { return }

            self.hasMicAudioLock.withLock { $0 = true }
            DispatchQueue.main.async { self.hasMicAudioSource = true }
            let fileRef = self.micAudioFile
            self.micWriterQueue.async { try? fileRef?.write(from: outBuf) }
        })

        // engine.start() calls prepare() internally — run on a background thread so it
        // doesn't block the MainActor while the HAL initialises.
        let started: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try engine.start(); cont.resume(returning: true) }
                catch { cont.resume(returning: false) }
            }
        }

        guard started else {
            inputNode.removeTap(onBus: 0)
            micAudioFile = nil
            logger.error("AVAudioEngine failed to start — recording system audio only")
            return
        }

        audioEngine = engine
        logger.info("Mic capture started")
    }

    // MARK: - IOProc (Core Audio real-time thread — system audio only)

    private func handleTapIOProc(inInputData: UnsafePointer<AudioBufferList>) {
        let paused = isPausedLock.withLock { $0 }
        guard !paused,
              let monoFmt   = monoInputFormat,
              let converter = tapConverter else { return }

        let numBuffers = Int(inInputData.pointee.mNumberBuffers)
        guard numBuffers > 0 else { return }

        // Find frame count from first non-empty buffer (non-interleaved float32)
        var frameCount = 0
        withUnsafePointer(to: inInputData.pointee.mBuffers) { base in
            for buf in UnsafeBufferPointer(start: base, count: numBuffers)
                where buf.mDataByteSize > 0 && buf.mData != nil {
                let nCh = max(1, Int(buf.mNumberChannels))
                frameCount = Int(buf.mDataByteSize) / (MemoryLayout<Float32>.size * nCh)
                break
            }
        }
        guard frameCount > 0 else { return }

        // Mix all tap channels to mono float32
        var mixed = [Float32](repeating: 0.0, count: frameCount)
        var nSources = 0
        withUnsafePointer(to: inInputData.pointee.mBuffers) { base in
            for buf in UnsafeBufferPointer(start: base, count: numBuffers) {
                guard buf.mDataByteSize > 0, let data = buf.mData else { continue }
                let nCh     = max(1, Int(buf.mNumberChannels))
                let nFrames = min(frameCount, Int(buf.mDataByteSize) / (MemoryLayout<Float32>.size * nCh))
                let samples = data.bindMemory(to: Float32.self, capacity: nFrames * nCh)
                for f in 0..<nFrames {
                    var s: Float32 = 0
                    for c in 0..<nCh { s += samples[f * nCh + c] }
                    mixed[f] += s / Float32(nCh)
                }
                nSources += 1
            }
        }
        guard nSources > 0 else { return }
        if nSources > 1 {
            let scale = 1.0 / Float32(nSources)
            for i in 0..<frameCount { mixed[i] *= scale }
        }

        hasSysAudioLock.withLock { $0 = true }
        DispatchQueue.main.async { self.hasSysAudioSource = true }

        // Wrap in AVAudioPCMBuffer and convert to 16kHz int16
        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: monoFmt,
                                               frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        inputBuf.frameLength = AVAudioFrameCount(frameCount)
        if let dst = inputBuf.floatChannelData?[0] {
            mixed.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: frameCount) }
        }

        let ratio  = converter.outputFormat.sampleRate / monoFmt.sampleRate
        let outCap = AVAudioFrameCount(Double(frameCount) * ratio) + 4
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outCap) else { return }

        var inputUsed = false
        converter.convert(to: outBuf, error: nil) { _, status in
            if inputUsed { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData; inputUsed = true; return inputBuf
        }
        guard outBuf.frameLength > 0 else { return }

        let fileRef = sysAudioFile
        sysWriterQueue.async { try? fileRef?.write(from: outBuf) }
    }

    // MARK: - Health check & stall detection

    private func scheduleHealthCheck() {
        cancelHealthCheck()
        // Check after 3 seconds whether audio data is actually flowing
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let hasSys = self.hasSysAudioLock.withLock { $0 }
                let hasMic = self.hasMicAudioLock.withLock { $0 }
                // Mirror lock values to @Published properties for view binding
                self.hasSysAudioSource = hasSys
                self.hasMicAudioSource = hasMic
                if !hasSys {
                    self.logger.warn("Health check: No system audio received after 3s — check 'System Audio Recording' permission in System Settings → Privacy")
                }
                if !hasMic {
                    // Mic failure is expected if permission was denied, so only warn if we attempted mic
                    if self.audioEngine != nil {
                        self.logger.warn("Health check: No mic audio received after 3s — mic may be unavailable or permission denied")
                    }
                }
            }
        }
        // Periodic stall detection: warn if no data for 10s during active recording
        stallCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.state == .recording else { return }
                let hasSys = self.hasSysAudioLock.withLock { $0 }
                if !hasSys {
                    self.logger.warn("Stall detection: No system audio data received in 10s — audio device may have changed or tap may have stopped")
                }
            }
        }
    }

    private func cancelHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        stallCheckTimer?.invalidate()
        stallCheckTimer = nil
    }

    // MARK: - Audio device change detection

    private func installDeviceChangeListeners() {
        guard !outputDeviceChangeListenerInstalled else { return }
        var outputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let outputStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &outputAddr,
            klarityAudioDeviceChangedCallback, nil)
        if outputStatus == noErr {
            outputDeviceChangeListenerInstalled = true
        }

        guard !inputDeviceChangeListenerInstalled else { return }
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let inputStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &inputAddr,
            klarityAudioDeviceChangedCallback, nil)
        if inputStatus == noErr {
            inputDeviceChangeListenerInstalled = true
        }
    }

    private func removeDeviceChangeListeners() {
        if outputDeviceChangeListenerInstalled {
            var outputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject), &outputAddr,
                klarityAudioDeviceChangedCallback, nil)
            outputDeviceChangeListenerInstalled = false
        }
        if inputDeviceChangeListenerInstalled {
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject), &inputAddr,
                klarityAudioDeviceChangedCallback, nil)
            inputDeviceChangeListenerInstalled = false
        }
    }

    // MARK: - Post-recording streaming mix

    /// Reads both WAV files in chunks, averages samples, writes final audio.wav.
    /// Streams the data — constant ~32KB working memory regardless of recording length.
    private func mixStreaming(sysURL: URL, micURL: URL, outputURL: URL) async throws {
        let float32Fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000, channels: 1, interleaved: true)!
        let int16Fmt   = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16_000, channels: 1, interleaved: true)!

        let sysFile = try AVAudioFile(forReading: sysURL, commonFormat: .pcmFormatFloat32, interleaved: true)
        let micFile = try AVAudioFile(forReading: micURL, commonFormat: .pcmFormatFloat32, interleaved: true)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let outFile = try AVAudioFile(forWriting: outputURL, settings: int16Fmt.settings,
                                      commonFormat: .pcmFormatInt16, interleaved: true)

        // Float32→Int16 converter (used per-chunk)
        guard let toInt16 = AVAudioConverter(from: float32Fmt, to: int16Fmt) else {
            throw AudioRecorderError.converterCreationFailed(float32Fmt, int16Fmt)
        }

        let chunkSize: AVAudioFrameCount = 4096
        let sysBuf  = AVAudioPCMBuffer(pcmFormat: float32Fmt, frameCapacity: chunkSize)!
        let micBuf  = AVAudioPCMBuffer(pcmFormat: float32Fmt, frameCapacity: chunkSize)!
        let mixBuf  = AVAudioPCMBuffer(pcmFormat: float32Fmt, frameCapacity: chunkSize)!
        let outBuf  = AVAudioPCMBuffer(pcmFormat: int16Fmt,   frameCapacity: chunkSize)!

        let totalFrames = max(sysFile.length, micFile.length)
        var pos: AVAudioFramePosition = 0

        while pos < totalFrames {
            let remaining = AVAudioFrameCount(totalFrames - pos)
            let toRead    = min(chunkSize, remaining)

            // Read sys chunk (pad with zeros if exhausted)
            let sysLeft = AVAudioFrameCount(max(0, sysFile.length - sysFile.framePosition))
            let sysRead = min(toRead, sysLeft)
            if sysRead > 0 {
                sysBuf.frameLength = sysRead
                try sysFile.read(into: sysBuf, frameCount: sysRead)
            }

            // Read mic chunk (pad with zeros if exhausted)
            let micLeft = AVAudioFrameCount(max(0, micFile.length - micFile.framePosition))
            let micRead = min(toRead, micLeft)
            if micRead > 0 {
                micBuf.frameLength = micRead
                try micFile.read(into: micBuf, frameCount: micRead)
            }

            // Mix sys + mic with mic boost
            // System audio (Zoom/Meet output) is loud; mic is naturally quiet.
            // Boost mic by ~9.5 dB (3×) so the local speaker is audible over the
            // louder system audio, then weight the mix 60/40 sys/mic to keep
            // system audio dominant while ensuring the mic is clearly heard.
            let micGain: Float32 = 3.0
            let sysWeight: Float32 = 0.6
            let micWeight: Float32 = 0.4
            mixBuf.frameLength = toRead
            let mixPtr = mixBuf.floatChannelData![0]
            let sysPtr = sysBuf.floatChannelData![0]
            let micPtr = micBuf.floatChannelData![0]
            for i in 0..<Int(toRead) {
                let s = i < sysRead ? sysPtr[i] : 0.0
                let m = i < micRead ? micPtr[i] : 0.0
                let mixed = s * sysWeight + (m * micGain) * micWeight
                mixPtr[i] = min(mixed, 1.0) // clamp to prevent clipping
            }

            // Convert mixed float32 chunk → int16 and write
            outBuf.frameLength = 0
            var inputConsumed = false
            toInt16.convert(to: outBuf, error: nil) { _, status in
                if inputConsumed { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData; inputConsumed = true; return mixBuf
            }
            if outBuf.frameLength > 0 { try outFile.write(from: outBuf) }

            pos += AVAudioFramePosition(toRead)
        }

        try? FileManager.default.removeItem(at: sysURL)
        try? FileManager.default.removeItem(at: micURL)
        logger.info("Mix complete: \(outputURL.lastPathComponent)")
    }

    // MARK: - Teardown

    /// Stops all audio capture (Core Audio tap + AVAudioEngine) and removes device listeners.
    /// Does NOT reset state or close files — used both during normal stop and before re-initialization.
    private func stopAllCapture() {
        teardownCoreAudio()
        stopMicCapture()
        removeDeviceChangeListeners()
    }

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
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapConverter   = nil
        monoInputFormat = nil
        deviceSampleRate = 48000.0
    }

    private func stopMicCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine  = nil
        micConverter = nil
        micConverterLock.withLock { $0 = nil }
    }

    private func teardownAll() {
        stopAllCapture()
        sysAudioFile = nil
        micAudioFile = nil
        sysTempURL.flatMap { try? FileManager.default.removeItem(at: $0) }
        micTempURL.flatMap { try? FileManager.default.removeItem(at: $0) }
        sysTempURL = nil
        micTempURL = nil
        hasSysAudioLock.withLock { $0 = false }
        hasMicAudioLock.withLock { $0 = false }
        hasSysAudioSource = false
        hasMicAudioSource = false
    }

    // MARK: - Device UID helpers

    private func defaultDeviceUID(selector: AudioObjectPropertySelector) throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st   = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                              &addr, 0, nil, &size, &deviceID)
        guard st == noErr else { throw AudioRecorderError.deviceLookupFailed(selector, st) }

        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidSt   = AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid)
        guard uidSt == noErr, let uid else { throw AudioRecorderError.deviceUIDFailed(deviceID, uidSt) }
        return uid.takeRetainedValue() as String
    }

    // MARK: - Leftover aggregate cleanup

    @available(macOS 14.2, *)
    private func destroyLeftoverAggregateDevice() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return }
        let count   = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &devices) == noErr else { return }
        for deviceID in devices {
            // Check for our well-known UID
            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
                  let uid else { continue }
            let uidStr = uid.takeRetainedValue() as String
            if uidStr == kAggregateUID {
                logger.warn("Destroying leftover aggregate (by UID): \(deviceID)")
                AudioHardwareDestroyAggregateDevice(deviceID)
                continue
            }

            // Also check by name for aggregates left from a different UID or corrupted state
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name) == noErr,
               let name, (name.takeRetainedValue() as String) == kAggregateName {
                logger.warn("Destroying leftover aggregate (by name): \(deviceID)")
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    // MARK: - Helpers

    private func moveFile(from src: URL, to dst: URL) {
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            logger.error("moveFile failed: \(error.localizedDescription)")
        }
    }

    private func resetToIdle() {
        cancelHealthCheck()
        timer?.invalidate(); timer = nil
        state = .idle
        isPausedLock.withLock { $0 = false }
        elapsedSeconds = 0
        pauseAccumulated = 0
        pauseStart = nil
        recordingStart = nil
        currentFilePath = nil
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

    private func stopTimer() { timer?.invalidate(); timer = nil }

    var formattedElapsed: String {
        let t = Int(elapsedSeconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Core Audio device change callback (free function required for C interop)

/// Core Audio property listener callback for default audio device changes.
/// Called on a Core Audio background thread when the default output or input device changes.
/// Logs a warning so the user knows the recording may be affected.
private func klarityAudioDeviceChangedCallback(
    _: AudioObjectID,
    _: UInt32,
    _: UnsafePointer<AudioObjectPropertyAddress>,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    // Can't call MainActor methods from here, so dispatch to main queue for logging.
    DispatchQueue.main.async {
        let logger = AppLogger(category: "AudioRecorder")
        logger.warn("Default audio device changed during recording — audio capture may be affected. If you changed audio devices (e.g., plugged/unplugged headphones), the recording may contain silence from the point of change.")
    }
    return noErr
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
            return "System audio tap failed (OSStatus \(s)). Grant 'System Audio Recording' in System Settings → Privacy."
        case .aggregateDeviceCreationFailed(let s):
            return "Aggregate audio device creation failed (OSStatus \(s))."
        case .formatQueryFailed(let s):
            return "Could not read aggregate device format (OSStatus \(s))."
        case .converterCreationFailed(let from, let to):
            return "Audio converter failed: \(from) → \(to)."
        case .ioProcCreationFailed(let s):
            return "IOProc creation failed (OSStatus \(s))."
        case .deviceStartFailed(let s):
            return "Audio device start failed (OSStatus \(s))."
        case .deviceLookupFailed(let sel, let s):
            return "Device lookup failed (selector \(sel), OSStatus \(s))."
        case .deviceUIDFailed(let id, let s):
            return "Device UID query failed (device \(id), OSStatus \(s))."
        }
    }
}