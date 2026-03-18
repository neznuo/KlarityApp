import AVFoundation
import ScreenCaptureKit
import Foundation
import CoreMedia
import os.log

// MARK: - Recording Mode

enum RecordingMode: String, CaseIterable, Identifiable {
    case systemAudioOnly      = "System Audio Only"
    case screenAndSystemAudio = "Screen & System Audio"
    var id: String { rawValue }
}

// MARK: - SingleTrackWriter

/// Writes CMSampleBuffers from exactly ONE audio source to a single .m4a file.
/// By accepting only one source format, the AAC encoder's AudioConverter is
/// initialized once and never sees a mismatched CMAudioFormatDescription.
final class SingleTrackWriter {
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var isSessionStarted = false
    private var isPaused = false
    private var lastPTS: CMTime = .invalid
    private var outputURL: URL?
    private var pendingBuffers: [CMSampleBuffer] = []

    private(set) var hasReceivedData = false

    private let queue: DispatchQueue
    private let label: String
    private let outputSettings: [String: Any]
    private let nominalTimescale: CMTimeScale

    init(label: String, outputSettings: [String: Any], nominalTimescale: CMTimeScale) {
        self.label = label
        self.outputSettings = outputSettings
        self.nominalTimescale = nominalTimescale
        self.queue = DispatchQueue(label: "com.klarity.\(label)TrackQueue", qos: .userInitiated)
    }

    func setup(url: URL) throws {
        outputURL = url
        isSessionStarted = false
        hasReceivedData = false
        isPaused = false
        lastPTS = .invalid

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(domain: "SingleTrackWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "[\(label)] AVAssetWriter cannot add audio input"])
        }
        writer.add(input)
        writer.startWriting()

        self.audioInput = input
        self.assetWriter = writer
        os_log("[%{public}@] AVAssetWriter ready. URL: %{public}@", label, url.path)
    }

    func write(buffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, !self.isPaused else { return }
            self.pendingBuffers.append(buffer)
            self.drainPendingBuffers()
        }
    }

    private func drainPendingBuffers() {
        guard let input = audioInput else { return }
        while !pendingBuffers.isEmpty && input.isReadyForMoreMediaData {
            let next = pendingBuffers.removeFirst()
            writeSync(buffer: next)
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in self?.isPaused = paused }
    }

    /// Finishes writing and returns the output URL on success, nil if no data was written.
    func finish() async -> URL? {
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, let writer = self.assetWriter else {
                    continuation.resume(returning: nil)
                    return
                }
                guard self.isSessionStarted && writer.status == .writing else {
                    writer.cancelWriting()
                    if let url = self.outputURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                    let url = self.outputURL
                    self.resetState()
                    _ = url // suppress unused warning
                    continuation.resume(returning: nil)
                    return
                }
                self.audioInput?.markAsFinished()
                let savedURL = self.outputURL
                let hadData = self.hasReceivedData
                let lbl = self.label
                writer.finishWriting {
                    if writer.status == .completed && hadData {
                        os_log("[%{public}@] finishWriting completed.", lbl)
                        continuation.resume(returning: savedURL)
                    } else {
                        os_log("[%{public}@] finishWriting failed (status=%d): %{public}@",
                               lbl, writer.status.rawValue,
                               String(describing: writer.error))
                        if let url = savedURL {
                            try? FileManager.default.removeItem(at: url)
                        }
                        continuation.resume(returning: nil)
                    }
                }
                self.resetState()
            }
        }
    }

    private func writeSync(buffer: CMSampleBuffer) {
        guard let writer = assetWriter, writer.status == .writing else {
            if assetWriter?.status == .failed {
                os_log("[%{public}@] AVAssetWriter failed: %{public}@",
                       label, String(describing: assetWriter?.error))
            }
            return
        }
        guard let input = audioInput, input.isReadyForMoreMediaData else { return }
        guard CMSampleBufferIsValid(buffer) else { return }

        let originalPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard originalPTS.isValid else { return }

        // Fix PTS collisions using the buffer's actual duration as the increment,
        // not 1 sample. Each audio buffer typically represents ~1024 samples (~21ms).
        var pts = originalPTS
        if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 {
            let dur = CMSampleBufferGetDuration(buffer)
            let inc = (dur.isValid && dur > .zero)
                ? dur
                : CMTime(value: CMTimeValue(1024), timescale: nominalTimescale)
            pts = CMTimeAdd(lastPTS, inc)
        }

        var outputBuffer = buffer
        if CMTimeCompare(pts, originalPTS) != 0 {
            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(buffer),
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )
            var retimed: CMSampleBuffer?
            let st = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: buffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &retimed
            )
            guard st == noErr, let r = retimed else {
                os_log("[%{public}@] Failed to retime buffer: %d", label, st)
                return
            }
            outputBuffer = r
        }

        if !isSessionStarted {
            writer.startSession(atSourceTime: pts)
            isSessionStarted = true
            os_log("[%{public}@] Session started at %.3fs", label, pts.seconds)
        }

        if input.append(outputBuffer) {
            lastPTS = pts
            hasReceivedData = true
        } else {
            os_log("[%{public}@] append failed: %{public}@", label, String(describing: writer.error))
        }
    }

    private func resetState() {
        assetWriter = nil
        audioInput = nil
        isSessionStarted = false
        hasReceivedData = false
        lastPTS = .invalid
        outputURL = nil
        pendingBuffers.removeAll()
    }
}

// MARK: - DualTrackMixer

/// Coordinates two SingleTrackWriter instances — one for system audio, one for mic audio.
/// On finish(), mixes both tracks into a single m4a using AVMutableComposition + AVAssetExportSession.
/// This avoids the format-mismatch corruption caused by writing two incompatible CMSampleBuffer
/// streams (SCStream Float32/non-interleaved vs. AVCapture PCM) into a single AVAssetWriterInput.
final class DualTrackMixer {
    private let systemWriter: SingleTrackWriter
    private let micWriter: SingleTrackWriter

    private var finalOutputURL: URL?
    private var systemTmpURL: URL?
    private var micTmpURL: URL?

    private var _hasStartedWriting = false
    var hasStartedWriting: Bool { _hasStartedWriting }

    init() {
        // SCStream delivers Float32, non-interleaved, 48kHz, stereo
        systemWriter = SingleTrackWriter(
            label: "system",
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ],
            nominalTimescale: 48000
        )
        // AVCaptureSession typically delivers PCM at 44100Hz or 48kHz, mono or stereo.
        // Keeping output as mono AAC; AVAssetWriterInput's AudioConverter handles SRC.
        micWriter = SingleTrackWriter(
            label: "mic",
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ],
            nominalTimescale: 44100
        )
    }

    func setup(url: URL) throws {
        finalOutputURL = url
        _hasStartedWriting = false

        let uuid = UUID().uuidString
        let dir = url.deletingLastPathComponent()
        let sysURL = dir.appendingPathComponent("system_tmp_\(uuid).m4a")
        let micURL = dir.appendingPathComponent("mic_tmp_\(uuid).m4a")

        systemTmpURL = sysURL
        micTmpURL = micURL

        try systemWriter.setup(url: sysURL)
        do {
            try micWriter.setup(url: micURL)
        } catch {
            // System writer already started — clean it up before rethrowing
            Task { _ = await systemWriter.finish() }
            throw error
        }
    }

    func writeSystemAudio(buffer: CMSampleBuffer) {
        _hasStartedWriting = true   // system audio is the primary source
        systemWriter.write(buffer: buffer)
    }

    func writeMicAudio(buffer: CMSampleBuffer) {
        micWriter.write(buffer: buffer)
    }

    func setPaused(_ paused: Bool) {
        systemWriter.setPaused(paused)
        micWriter.setPaused(paused)
    }

    func finish() async {
        // Drain both writers in parallel
        async let sysFinish = systemWriter.finish()
        async let micFinish = micWriter.finish()
        let (sysURL, micURL) = await (sysFinish, micFinish)

        defer {
            finalOutputURL = nil
            systemTmpURL = nil
            micTmpURL = nil
        }

        guard let finalURL = finalOutputURL else { return }

        if let sysURL = sysURL, let micURL = micURL {
            await composeTracks(systemURL: sysURL, micURL: micURL, outputURL: finalURL)
        } else if let sysURL = sysURL {
            os_log("[DualTrackMixer] Mic had no data; using system-audio-only output.")
            moveFile(from: sysURL, to: finalURL)
            if let micURL = micURL { try? FileManager.default.removeItem(at: micURL) }
        } else {
            os_log("[DualTrackMixer-Error] Both writers produced no output.")
            if let micURL = micURL { try? FileManager.default.removeItem(at: micURL) }
        }
    }

    private func composeTracks(systemURL: URL, micURL: URL, outputURL: URL) async {
        let sysAsset = AVURLAsset(url: systemURL)
        let micAsset = AVURLAsset(url: micURL)

        let sysDuration: CMTime
        let micDuration: CMTime
        do {
            sysDuration = try await sysAsset.load(.duration)
            micDuration = try await micAsset.load(.duration)
        } catch {
            os_log("[DualTrackMixer-Error] Failed to load asset durations: %{public}@",
                   error.localizedDescription)
            moveFile(from: systemURL, to: outputURL)
            try? FileManager.default.removeItem(at: micURL)
            return
        }

        let composition = AVMutableComposition()
        guard let sysTrack = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid),
              let micTrack = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            os_log("[DualTrackMixer-Error] Could not add composition tracks.")
            moveFile(from: systemURL, to: outputURL)
            try? FileManager.default.removeItem(at: micURL)
            return
        }

        do {
            let sysSources = try await sysAsset.loadTracks(withMediaType: .audio)
            let micSources = try await micAsset.loadTracks(withMediaType: .audio)
            guard let sysSource = sysSources.first, let micSource = micSources.first else {
                throw NSError(domain: "DualTrackMixer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Missing audio tracks in temp assets"])
            }
            try sysTrack.insertTimeRange(CMTimeRange(start: .zero, duration: sysDuration),
                                         of: sysSource, at: .zero)
            try micTrack.insertTimeRange(CMTimeRange(start: .zero, duration: micDuration),
                                         of: micSource, at: .zero)
        } catch {
            os_log("[DualTrackMixer-Error] Composition build failed: %{public}@",
                   error.localizedDescription)
            moveFile(from: systemURL, to: outputURL)
            try? FileManager.default.removeItem(at: micURL)
            return
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            os_log("[DualTrackMixer-Error] Could not create AVAssetExportSession.")
            moveFile(from: systemURL, to: outputURL)
            try? FileManager.default.removeItem(at: micURL)
            return
        }

        session.outputURL = outputURL
        session.outputFileType = .m4a

        await session.export()

        if session.status == .completed {
            os_log("[DualTrackMixer] Export completed: %{public}@", outputURL.path)
        } else {
            os_log("[DualTrackMixer-Error] Export failed (status=%d): %{public}@",
                   session.status.rawValue,
                   session.error?.localizedDescription ?? "unknown")
            moveFile(from: systemURL, to: outputURL)
        }

        try? FileManager.default.removeItem(at: systemURL)
        try? FileManager.default.removeItem(at: micURL)
    }

    private func moveFile(from source: URL, to destination: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            os_log("[DualTrackMixer-Error] moveFile failed: %{public}@", error.localizedDescription)
        }
    }
}

// MARK: - VideoFileMixer

/// Thread-safe writer for the screen + audio output (recording.mp4).
/// Only used in `.screenAndSystemAudio` mode.
final class VideoFileMixer {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var isWriterStarted = false
    private let queue = DispatchQueue(label: "com.klarity.videoMixerRef.currentQueue")

    func setup(url: URL, displayWidth: Int, displayHeight: Int) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        assetWriter = try AVAssetWriter(url: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: displayWidth,
            AVVideoHeightKey: displayHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true
        if let vi = videoInput, assetWriter!.canAdd(vi) {
            assetWriter!.add(vi)
        }

        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let channelLayoutData = Data(bytes: &channelLayout, count: MemoryLayout<AudioChannelLayout>.size)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: channelLayoutData,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false
        ]

        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        if let ai = audioInput, assetWriter!.canAdd(ai) {
            assetWriter!.add(ai)
        }

        assetWriter?.startWriting()
    }

    func writeVideo(buffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.write(buffer: buffer, to: self?.videoInput) }
    }

    func writeAudio(buffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.write(buffer: buffer, to: self?.audioInput) }
    }

    private func write(buffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let writer = assetWriter, writer.status == .writing,
              let input = input, input.isReadyForMoreMediaData else { return }

        if !isWriterStarted {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(buffer)
            if presentationTime.isValid {
                writer.startSession(atSourceTime: presentationTime)
                isWriterStarted = true
            }
        }

        if isWriterStarted {
            input.append(buffer)
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, let writer = self.assetWriter else {
                    continuation.resume()
                    return
                }

                if self.isWriterStarted && writer.status == .writing {
                    self.videoInput?.markAsFinished()
                    self.audioInput?.markAsFinished()
                    writer.finishWriting { continuation.resume() }
                } else {
                    writer.cancelWriting()
                    continuation.resume()
                }

                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.isWriterStarted = false
            }
        }
    }
}

// MARK: - AudioRecorder

/// Manages local recording using ScreenCaptureKit and AVCaptureSession.
/// Supports two modes: system-audio-only (audio.wav) and screen+audio (audio.wav + recording.mp4).
@MainActor
final class AudioRecorder: NSObject, ObservableObject, SCStreamOutput {
    enum RecordingState {
        case idle, preparing, recording, paused
    }

    @Published private(set) var state: RecordingState = .idle
    @Published var elapsedSeconds: Double = 0
    @Published var currentFilePath: URL?
    @Published var errorMessage: String?

    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?

    private let mixer = DualTrackMixer()
    // Wrapped in a `let` container so nonisolated SCStream callbacks can access it
    // without actor-isolation errors (same pattern as `mixer` above).
    private final class VideoMixerRef { var current: VideoFileMixer? }
    private let videoMixerRef = VideoMixerRef()
    private var currentMode: RecordingMode = .systemAudioOnly

    private var timer: Timer?
    private var recordingStart: Date?
    private var pauseAccumulated: Double = 0
    private var pauseStart: Date?

    private var controlState: RecordingState = .idle
    private var isPreparingCapture = false

    private let logger = Logger(subsystem: "com.klarity.meeting-assistant", category: "AudioRecorder")

    // MARK: - Public API

    func startRecording(to audioURL: URL, videoURL: URL? = nil, mode: RecordingMode = .systemAudioOnly) {
        errorMessage = nil
        guard controlState == .idle, !isPreparingCapture else { return }

        currentMode = mode
        state = .preparing  // Show "preparing" while hardware negotiates
        isPreparingCapture = true
        currentFilePath = audioURL

        Task {
            do {
                // Step 1: Request Screen Recording permission
                self.logger.info("Step 1: Requesting SCShareableContent...")
                let content: SCShareableContent
                do {
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                } catch {
                    let e = "SCShareableContent failed: \(error.localizedDescription)"
                    self.logger.error("\(e, privacy: .public)")
                    self.errorMessage = e
                    self.resetToIdle()
                    return
                }

                guard let display = content.displays.first else {
                    self.errorMessage = "No display found for ScreenCaptureKit."
                    self.resetToIdle()
                    return
                }
                self.logger.info("Step 1: OK — found \(content.displays.count, privacy: .public) displays")

                // Step 2: Setup audio mixer
                self.logger.info("Step 2: Setting up audio mixer...")
                do {
                    try self.mixer.setup(url: audioURL)
                } catch {
                    let e = "Audio mixer setup failed: \(error.localizedDescription)"
                    self.logger.error("\(e, privacy: .public)")
                    self.errorMessage = e
                    self.resetToIdle()
                    return
                }
                self.logger.info("Step 2: Audio mixer OK")

                // Step 3: Setup video mixer (screen mode only)
                if mode == .screenAndSystemAudio, let vURL = videoURL {
                    self.logger.info("Step 3: Setting up video mixer...")
                    let vm = VideoFileMixer()
                    do {
                        try vm.setup(url: vURL, displayWidth: display.width, displayHeight: display.height)
                        self.videoMixerRef.current = vm
                    } catch {
                        let e = "Video mixer setup failed: \(error.localizedDescription)"
                        self.logger.error("\(e, privacy: .public)")
                        self.errorMessage = e
                        self.resetToIdle()
                        return
                    }
                    self.logger.info("Step 3: Video mixer OK")
                } else {
                    self.logger.info("Step 3: Skipped (system audio only mode)")
                }

                // Step 4: Setup microphone
                self.logger.info("Step 4: Setting up microphone...")
                self.setupMicrophone()
                self.logger.info("Step 4: Mic OK")

                // Step 5: Setup SCStream
                self.logger.info("Step 5: Setting up SCStream...")
                do {
                    try self.setupSystemAudio(display: display, mode: mode)
                } catch {
                    let e = "SCStream setup failed: \(error.localizedDescription)"
                    self.logger.error("\(e, privacy: .public)")
                    self.errorMessage = e
                    self.resetToIdle()
                    return
                }
                self.logger.info("Step 5: SCStream OK")

                // Step 6: Start capture — this can take 15-20 seconds with Bluetooth audio
                do {
                    try self.audioEngine?.start()
                } catch {
                    let e = "Audio engine start failed: \(error.localizedDescription)"
                    self.logger.error("\(e, privacy: .public)")
                    self.errorMessage = e
                    self.resetToIdle()
                    return
                }
                self.logger.info("Step 6: Starting SCStream capture...")
                do {
                    try await self.stream?.startCapture()
                } catch {
                    let e = "startCapture failed: \(error.localizedDescription)"
                    self.logger.error("\(e, privacy: .public)")
                    self.errorMessage = e
                    self.resetToIdle()
                    return
                }
                self.logger.info("Step 6: Capture started OK")

                // Only NOW flip to recording — hardware is confirmed ready
                self.controlState = .recording
                self.isPreparingCapture = false
                self.state = .recording
                self.recordingStart = Date()
                self.startTimer()

            } catch {
                let errStr = error.localizedDescription
                self.logger.error("Recording failed (uncaught): \(errStr, privacy: .public)")
                self.errorMessage = "Failed to start recording: \(errStr)"
                self.resetToIdle()
                self.cleanup()
            }
        }
    }

    func pauseRecording() {
        guard controlState == .recording else { return }
        mixer.setPaused(true)
        state = .paused
        controlState = .paused
        pauseStart = Date()
        stopTimer()
    }

    func resumeRecording() {
        guard controlState == .paused else { return }
        pauseAccumulated += Date().timeIntervalSince(pauseStart ?? Date())
        pauseStart = nil
        mixer.setPaused(false)
        state = .recording
        controlState = .recording
        startTimer()
    }

    func stopRecording() async -> URL? {
        guard controlState == .recording || controlState == .paused else { return nil }

        let path = currentFilePath
        stopTimer()
        state = .idle
        controlState = .idle
        isPreparingCapture = false
        elapsedSeconds = 0
        pauseAccumulated = 0

        // Stop mic engine first
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // Stop SCStream next
        do {
            try await stream?.stopCapture()
        } catch {
            logger.error("Error stopping SCStream: \(error.localizedDescription)")
        }

        let successfullyCapturedData = mixer.hasStartedWriting

        await mixer.finish()
        await videoMixerRef.current?.finish()
        videoMixerRef.current = nil
        
        // Wipe hardware locks
        cleanup()

        if !successfullyCapturedData {
            logger.error("Recording stopped but 0 audio buffers were received from macOS.")
            self.errorMessage = "Recording Failed: macOS blocked microphone/screen access. Please go to Settings > Permissions and hit Reset."
            if let p = path { try? FileManager.default.removeItem(at: p) }
            return nil
        }

        logger.info("Recording saved to: \(path?.path ?? "nil", privacy: .public)")
        return path
    }

    // MARK: - Setup Subsystems

    private func setupMicrophone() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Note: setVoiceProcessingEnabled(true) was removed because VPIO puts macOS
        // into a system-wide "phone call" audio mode that reduces playback volume for
        // all applications, making the user's active meeting (Zoom/Teams/etc.) inaudible.
        // The mild mic echo in the recording is acceptable — ElevenLabs Scribe handles it.

        let hwFormat = inputNode.inputFormat(forBus: 0)
        let mixer = self.mixer  // capture the reference for the tap closure

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, time in
            guard let sb = makeCMSampleBuffer(from: buffer, at: time) else { return }
            mixer.writeMicAudio(buffer: sb)
        }

        engine.prepare()
        audioEngine = engine
    }

    private func setupSystemAudio(display: SCDisplay, mode: RecordingMode) throws {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()

        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = display.width
        config.height = display.height

        if mode == .screenAndSystemAudio {
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        }

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(self, type: .audio,
                                    sampleHandlerQueue: DispatchQueue(label: "com.klarity.sysAudioQueue"))

        if mode == .screenAndSystemAudio {
            try stream?.addStreamOutput(self, type: .screen,
                                        sampleHandlerQueue: DispatchQueue(label: "com.klarity.screenQueue"))
        }
    }

    // MARK: - Callbacks

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            os_log("[AudioRecorder] SCStream audio buffer received")
            mixer.writeSystemAudio(buffer: sampleBuffer)
            videoMixerRef.current?.writeAudio(buffer: sampleBuffer)
        case .screen:
            videoMixerRef.current?.writeVideo(buffer: sampleBuffer)
        default:
            break
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
        recordingStart = nil
        currentFilePath = nil
    }

    private func cleanup() {
        if let stream = stream {
            try? stream.removeStreamOutput(self, type: .audio)
            try? stream.removeStreamOutput(self, type: .screen)
        }
        stream = nil
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - Timer

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
}

// MARK: - AVAudioPCMBuffer → CMSampleBuffer conversion (used by AVAudioEngine mic tap)

private func makeCMSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, at time: AVAudioTime) -> CMSampleBuffer? {
    guard pcmBuffer.frameLength > 0 else { return nil }

    var asbd = pcmBuffer.format.streamDescription.pointee
    var fmtDesc: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &fmtDesc
    ) == noErr, let fmtDesc else { return nil }

    let sampleRate = pcmBuffer.format.sampleRate
    let pts: CMTime
    if time.isSampleTimeValid {
        pts = CMTime(value: CMTimeValue(time.sampleTime), timescale: CMTimeScale(sampleRate))
    } else {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(time.hostTime) * Double(info.numer) / Double(info.denom)
        pts = CMTime(seconds: nanos / 1_000_000_000, preferredTimescale: CMTimeScale(sampleRate))
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: fmtDesc,
        sampleCount: CMItemCount(pcmBuffer.frameLength),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else { return nil }

    guard CMSampleBufferSetDataBufferFromAudioBufferList(
        sampleBuffer,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        bufferList: pcmBuffer.audioBufferList
    ) == noErr else { return nil }

    return sampleBuffer
}

extension AudioRecorder {
    var formattedElapsed: String {
        let total = Int(elapsedSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
