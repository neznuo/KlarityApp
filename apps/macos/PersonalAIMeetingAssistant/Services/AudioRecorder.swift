@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.log

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

    // MARK: Shared state

    // isPaused is read from real-time threads — plain Bool is atomic on arm64/x86_64.
    private var isPaused: Bool = false
    private var hasSysAudio: Bool = false
    private var hasMicAudio: Bool = false
    private var controlState: RecordingState = .idle
    private var isPreparingCapture: Bool = false

    // MARK: Timer

    private var timer: Timer?
    private var recordingStart: Date?
    private var pauseAccumulated: Double = 0
    private var pauseStart: Date?

    private let logger = AppLogger(category: "AudioRecorder")
    private let kAggregateUID = "com.klarity.meetingrecorder.aggregate.v2"

    // MARK: - Public API

    func startRecording(to audioURL: URL) {
        errorMessage = nil
        guard controlState == .idle, !isPreparingCapture else { return }

        guard #available(macOS 14.2, *) else {
            errorMessage = "Meeting recording requires macOS 14.2 (Sonoma) or later."
            return
        }

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

        // 1. Stop both capture paths
        teardownCoreAudio()
        stopMicCapture()

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

        guard hasSysAudio, let sysURL = sysTmp, let outputURL = savedPath else {
            logger.error("No system audio received — possible permission denial or tap failure")
            errorMessage = "Recording failed: No audio captured. Grant 'System Audio Recording' permission in System Settings → Privacy, then try again."
            sysTmp.flatMap { try? FileManager.default.removeItem(at: $0) }
            micTmp.flatMap { try? FileManager.default.removeItem(at: $0) }
            return nil
        }

        // 4. Mix system audio + mic into the final output file
        if hasMicAudio, let micURL = micTmp {
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

        hasSysAudio = false
        hasMicAudio = false
        logger.info("Recording saved: \(outputURL.path)")
        return outputURL
    }

    // MARK: - Setup

    @available(macOS 14.2, *)
    private func setupAndStart(audioURL: URL) async throws {
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
        let aggregateProps: [String: Any] = [
            kAudioAggregateDeviceNameKey:          "KlarityMeetingRecorder",
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
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown)
            throw AudioRecorderError.aggregateDeviceCreationFailed(aggStatus)
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
        let procSt = AudioDeviceCreateIOProcIDWithBlock(&localProcID, localAggID, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleTapIOProc(inInputData: inInputData)
        }
        guard procSt == noErr, let procID = localProcID else { throw AudioRecorderError.ioProcCreationFailed(procSt) }
        ioProcID = procID

        let startSt = AudioDeviceStart(localAggID, procID)
        guard startSt == noErr else {
            AudioDeviceDestroyIOProcID(localAggID, procID); ioProcID = nil
            throw AudioRecorderError.deviceStartFailed(startSt)
        }
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

        // Install tap with nil format BEFORE engine.start().
        // AVAudioEngine will negotiate the correct hardware format during start.
        // Converter is created lazily on the first callback using buffer.format, which is
        // always the true delivered format regardless of what outputFormat() reports pre-start.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self, !self.isPaused, buffer.frameLength > 0 else { return }

            // Lazy one-time converter creation using the actual delivered buffer format.
            if self.micConverter == nil {
                self.micConverter = AVAudioConverter(from: buffer.format, to: outputFormat)
            }
            guard let converter = self.micConverter else { return }

            let ratio  = outputFormat.sampleRate / buffer.format.sampleRate
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCap) else { return }

            var inputUsed = false
            converter.convert(to: outBuf, error: nil) { _, status in
                if inputUsed { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData; inputUsed = true
                return buffer
            }
            guard outBuf.frameLength > 0 else { return }

            self.hasMicAudio = true
            let fileRef = self.micAudioFile
            self.micWriterQueue.async { try? fileRef?.write(from: outBuf) }
        }

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
        guard !isPaused,
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

        hasSysAudio = true

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

            // Average sys + mic sample by sample
            mixBuf.frameLength = toRead
            let mixPtr = mixBuf.floatChannelData![0]
            let sysPtr = sysBuf.floatChannelData![0]
            let micPtr = micBuf.floatChannelData![0]
            for i in 0..<Int(toRead) {
                let s = i < sysRead ? sysPtr[i] : 0.0
                let m = i < micRead ? micPtr[i] : 0.0
                mixPtr[i] = (s + m) * 0.5
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
    }

    private func teardownAll() {
        teardownCoreAudio()
        stopMicCapture()
        sysAudioFile = nil
        micAudioFile = nil
        sysTempURL.flatMap { try? FileManager.default.removeItem(at: $0) }
        micTempURL.flatMap { try? FileManager.default.removeItem(at: $0) }
        sysTempURL = nil
        micTempURL = nil
        hasSysAudio  = false
        hasMicAudio  = false
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
            var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
                  let uid else { continue }
            if (uid.takeRetainedValue() as String) == kAggregateUID {
                logger.warn("Destroying leftover aggregate: \(deviceID)")
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
        hasSysAudio = false
        hasMicAudio = false
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
