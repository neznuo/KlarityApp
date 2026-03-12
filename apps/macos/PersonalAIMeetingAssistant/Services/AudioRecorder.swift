import AVFoundation
import ScreenCaptureKit
import Foundation
import os.log

// MARK: - Recording Mode

enum RecordingMode: String, CaseIterable, Identifiable {
    case systemAudioOnly      = "System Audio Only"
    case screenAndSystemAudio = "Screen & System Audio"
    var id: String { rawValue }
}

// MARK: - AudioFileMixer

/// Thread-safe writer for the audio-only output (audio.m4a).
/// IMPORTANT: .m4a containers only support a SINGLE audio track.
/// Both mic and system audio are routed through the same input sequentially.
final class AudioFileMixer {
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var isWriterStarted = false
    private var isPaused = false
    private let queue = DispatchQueue(label: "com.klarity.mixerQueue", qos: .userInitiated)

    // Reset between recordings
    private var _hasStartedWriting = false
    var hasStartedWriting: Bool { _hasStartedWriting }

    func setup(url: URL) throws {
        // Full reset of state for a clean new recording
        isWriterStarted = false
        _hasStartedWriting = false
        isPaused = false
        audioInput = nil
        assetWriter = nil

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(url: url, fileType: .m4a)

        // Single AAC audio track — m4a supports exactly 1 audio track.
        // AAC auto-resamples and downmixes any SCStream Float32 / multi-channel formats.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(domain: "AudioFileMixer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter cannot add audio input"])
        }
        writer.add(input)
        writer.startWriting()

        self.audioInput = input
        self.assetWriter = writer
        os_log("[Mixer] AVAssetWriter ready. URL: %{public}@", url.path)
    }

    func writeSystemAudio(buffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, !self.isPaused else { return }
            self._hasStartedWriting = true
            self.write(buffer: buffer)
        }
    }

    func writeMicAudio(buffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, !self.isPaused else { return }
            self._hasStartedWriting = true
            self.write(buffer: buffer)
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in self?.isPaused = paused }
    }

    private func write(buffer: CMSampleBuffer) {
        guard let writer = assetWriter else { return }
        guard writer.status == .writing else {
            if writer.status == .failed {
                os_log("[Mixer-Error] AVAssetWriter failed: %{public}@", String(describing: writer.error))
            }
            return
        }
        guard let input = audioInput, input.isReadyForMoreMediaData else { return }

        if !isWriterStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isValid else { return }
            writer.startSession(atSourceTime: pts)
            isWriterStarted = true
            os_log("[Mixer] Session started at %.3f", pts.seconds)
        }

        if !input.append(buffer) {
            os_log("[Mixer-Error] append failed: %{public}@", String(describing: writer.error))
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
                    self.audioInput?.markAsFinished()
                    writer.finishWriting {
                        os_log("[Mixer] finishWriting done, status=%d", writer.status.rawValue)
                        continuation.resume()
                    }
                } else {
                    os_log("[Mixer] Writer not started (status=%d), cancelling.", writer.status.rawValue)
                    writer.cancelWriting()
                    continuation.resume()
                }

                self.assetWriter = nil
                self.audioInput = nil
                self.isWriterStarted = false
                self._hasStartedWriting = false
            }
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
final class AudioRecorder: NSObject, ObservableObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum RecordingState {
        case idle, preparing, recording, paused
    }

    @Published var state: RecordingState = .idle
    @Published var elapsedSeconds: Double = 0
    @Published var currentFilePath: URL?
    @Published var errorMessage: String?

    private var stream: SCStream?
    private var captureSession: AVCaptureSession?

    private let mixer = AudioFileMixer()
    // Wrapped in a `let` container so nonisolated SCStream callbacks can access it
    // without actor-isolation errors (same pattern as `mixer` above).
    private final class VideoMixerRef { var current: VideoFileMixer? }
    private let videoMixerRef = VideoMixerRef()
    private var currentMode: RecordingMode = .systemAudioOnly

    private var timer: Timer?
    private var recordingStart: Date?
    private var pauseAccumulated: Double = 0
    private var pauseStart: Date?

    private let logger = Logger(subsystem: "com.klarity.meeting-assistant", category: "AudioRecorder")

    // MARK: - Public API

    func startRecording(to audioURL: URL, videoURL: URL? = nil, mode: RecordingMode = .systemAudioOnly) {
        errorMessage = nil
        guard state == .idle else { return }

        currentMode = mode
        state = .preparing  // Show "preparing" while hardware negotiates
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
                do {
                    try self.setupMicrophone()
                } catch {
                    let e = "Mic setup failed: \(error.localizedDescription)"
                    self.logger.error("\(e, privacy: .public)")
                    self.errorMessage = e
                    self.resetToIdle()
                    return
                }
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
                self.captureSession?.startRunning()
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
        guard state == .recording else { return }
        mixer.setPaused(true)
        state = .paused
        pauseStart = Date()
        stopTimer()
    }

    func resumeRecording() {
        guard state == .paused else { return }
        pauseAccumulated += Date().timeIntervalSince(pauseStart ?? Date())
        pauseStart = nil
        mixer.setPaused(false)
        state = .recording
        startTimer()
    }

    func stopRecording() async -> URL? {
        guard state != .idle else { return nil }

        let path = currentFilePath
        stopTimer()
        state = .idle
        elapsedSeconds = 0
        pauseAccumulated = 0

        // Stop AV Capture first
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }

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

    private func setupMicrophone() throws {
        captureSession = AVCaptureSession()
        guard let session = captureSession else { return }

        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone found."])
        }

        let micInput = try AVCaptureDeviceInput(device: micDevice)
        if session.canAddInput(micInput) { session.addInput(micInput) }

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.klarity.micQueue"))
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
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

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        os_log("[AudioRecorder] Mic buffer received")
        mixer.writeMicAudio(buffer: sampleBuffer)
    }

    // MARK: - Helpers

    private func resetToIdle() {
        stopTimer()
        state = .idle
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
        
        if let session = captureSession {
            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                if let audioOutput = output as? AVCaptureAudioDataOutput {
                    audioOutput.setSampleBufferDelegate(nil, queue: nil)
                }
                session.removeOutput(output)
            }
        }
        captureSession = nil
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
