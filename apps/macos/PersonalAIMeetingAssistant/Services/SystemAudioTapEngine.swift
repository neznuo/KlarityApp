import AVFoundation
import AudioToolbox
import os.log

/// Captures all system audio output using the Core Audio Process Tap API (macOS 14.2+).
///
/// Replaces SCStream for audio-only recording. SCStream has a confirmed bug on Sonoma/Sequoia
/// where it silently stops delivering audio after a few minutes in audio-only mode.
/// Core Audio taps are purpose-built for system audio capture and do not have this limitation.
///
/// Architecture:
///  1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` — taps all system output
///     as a stereo mixdown, excluding no processes.
///  2. `AudioHardwareCreateProcessTap` — creates the tap audio object (macOS 14.2+).
///  3. `AudioHardwareCreateAggregateDevice` — wraps tap + system output in a virtual device.
///  4. `AudioDeviceCreateIOProcIDWithBlock` — delivers raw PCM buffers from the aggregate device.
///  5. `AVAudioConverter` normalises every buffer to 48 kHz Float32 non-interleaved stereo
///     before calling the handler, regardless of the tap's native rate/format.
@available(macOS 14.2, *)
final class SystemAudioTapEngine {
    typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    /// Canonical output format handed to callers.  DualTrackMixer expects this.
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 48_000,
                                            channels: 2,
                                            interleaved: false)!

    private let bufferHandler: BufferHandler
    private var processTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    private let queue = DispatchQueue(label: "com.klarity.systemAudioTap", qos: .userInitiated)

    // Lazily-created on the first IOProc callback once the actual delivery format is known.
    private var audioConverter: AVAudioConverter?

    init(bufferHandler: @escaping BufferHandler) {
        self.bufferHandler = bufferHandler
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        // 1. Tap all system audio output as stereo; exclude no processes (empty = capture all).
        //    muteBehavior = .unmuted so the user can still hear meeting audio while recording.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        // 2. Create the process tap object.
        var tapID: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else {
            throw tapError("AudioHardwareCreateProcessTap", status: err)
        }
        processTapID = tapID
        os_log("[SystemAudioTapEngine] Process tap created (id=%d)", tapID)

        // 3. Get current system output device UID. The aggregate device uses it as the
        //    main sub-device so it inherits the correct clock and sample rate.
        let systemOutputID = try readDefaultSystemOutputDeviceID()
        let outputUID = try readDeviceUID(deviceID: systemOutputID)

        // 4. Read the tap's native stream format before creating the aggregate device.
        var tapASBD = try readTapStreamBasicDescription(tapID: tapID)
        guard let tapFormat = AVAudioFormat(streamDescription: &tapASBD) else {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = kAudioObjectUnknown
            throw tapError("AVAudioFormat(streamDescription:)", status: -1)
        }

        // Log the exact ASBD so we can diagnose format/interleaving issues in Console.
        os_log("[SystemAudioTapEngine] Tap format: %.0f Hz, %d ch, interleaved=%d, bitsPerCh=%d, bytesPerFrame=%d, bytesPerPacket=%d, framesPerPacket=%d, formatFlags=0x%x",
               tapFormat.sampleRate,
               tapFormat.channelCount,
               tapFormat.isInterleaved ? 1 : 0,
               tapASBD.mBitsPerChannel,
               tapASBD.mBytesPerFrame,
               tapASBD.mBytesPerPacket,
               tapASBD.mFramesPerPacket,
               tapASBD.mFormatFlags)

        // 5. Build the aggregate device that exposes the tap as an input stream.
        //    The sub-device list provides the clock reference; the tap list provides capture.
        let aggUID = UUID().uuidString
        let tapUID = tapDescription.uuid.uuidString

        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Klarity System Audio",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID)
        guard err == noErr else {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = kAudioObjectUnknown
            throw tapError("AudioHardwareCreateAggregateDevice", status: err)
        }
        aggregateDeviceID = aggID
        os_log("[SystemAudioTapEngine] Aggregate device created (id=%d)", aggID)

        // 6. Register an I/O proc to receive audio buffers on `queue`.
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue) { [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleAudio(bufferList: inInputData, timeStamp: inInputTime, tapFormat: tapFormat)
        }
        guard err == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(processTapID)
            aggregateDeviceID = kAudioObjectUnknown
            processTapID = kAudioObjectUnknown
            throw tapError("AudioDeviceCreateIOProcIDWithBlock", status: err)
        }
        deviceProcID = procID

        // 7. Start the aggregate device.
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            if let p = deviceProcID { AudioDeviceDestroyIOProcID(aggregateDeviceID, p) }
            deviceProcID = nil
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(processTapID)
            aggregateDeviceID = kAudioObjectUnknown
            processTapID = kAudioObjectUnknown
            throw tapError("AudioDeviceStart", status: err)
        }

        isRunning = true
        os_log("[SystemAudioTapEngine] Started — %.0f Hz, %d ch",
               tapFormat.sampleRate, tapFormat.channelCount)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let p = deviceProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, p)
                deviceProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if processTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(processTapID)
            processTapID = kAudioObjectUnknown
        }

        _loggedFirstCallback = false
        audioConverter = nil
        os_log("[SystemAudioTapEngine] Stopped")
    }

    deinit { stop() }

    // MARK: - IOProc callback

    private var _loggedFirstCallback = false

    private func handleAudio(bufferList: UnsafePointer<AudioBufferList>,
                              timeStamp: UnsafePointer<AudioTimeStamp>,
                              tapFormat: AVAudioFormat) {
        let nBufs = Int(bufferList.pointee.mNumberBuffers)
        let nCh   = Int(tapFormat.channelCount)

        // ── Step 1: resolve actual delivery format ────────────────────────────
        // kAudioTapPropertyFormat sometimes reports INTERLEAVED stereo (mBytesPerFrame=8)
        // but the IOProc delivers as 2 separate non-interleaved channel buffers.
        // AVAudioPCMBuffer(bufferListNoCopy:) computes frameLength = buf0.bytes / mBytesPerFrame,
        // so the interleaving mismatch halves frameLength → 2× playback speed (chipmunk).
        // Detect and correct: if format says interleaved but delivery has nBufs == channelCount,
        // the data is actually non-interleaved — use an equivalent non-interleaved format.
        let deliveryFormat: AVAudioFormat
        if tapFormat.isInterleaved && nBufs == nCh && nCh > 1 {
            deliveryFormat = AVAudioFormat(commonFormat: tapFormat.commonFormat,
                                           sampleRate: tapFormat.sampleRate,
                                           channels: tapFormat.channelCount,
                                           interleaved: false) ?? tapFormat
        } else {
            deliveryFormat = tapFormat
        }

        // Log once to Console so we can verify what the tap is actually delivering.
        if !_loggedFirstCallback {
            _loggedFirstCallback = true
            let b0bytes = Int(bufferList.pointee.mBuffers.mDataByteSize)
            let b0ch    = Int(bufferList.pointee.mBuffers.mNumberChannels)
            os_log("[SystemAudioTapEngine] IOProc first callback — nBufs=%d buf0.nCh=%d buf0.bytes=%d tapFmt: %.0fHz interleaved=%d bpf=%d → deliveryFmt: %.0fHz interleaved=%d bpf=%d",
                   nBufs, b0ch, b0bytes,
                   tapFormat.sampleRate, tapFormat.isInterleaved ? 1 : 0,
                   tapFormat.streamDescription.pointee.mBytesPerFrame,
                   deliveryFormat.sampleRate, deliveryFormat.isInterleaved ? 1 : 0,
                   deliveryFormat.streamDescription.pointee.mBytesPerFrame)
        }

        // ── Step 2: wrap the IOProc buffer (no-copy) and own-copy it ─────────
        guard let noCopy = AVAudioPCMBuffer(pcmFormat: deliveryFormat,
                                            bufferListNoCopy: bufferList,
                                            deallocator: nil),
              let inputBuffer = noCopy.copy() as? AVAudioPCMBuffer,
              inputBuffer.frameLength > 0 else { return }

        // ── Step 3: lazy-create AVAudioConverter on first callback ────────────
        // Converts tap-native format (any rate, any layout) → 48 kHz Float32
        // non-interleaved stereo.  This handles ALL cases:
        //   • Sample-rate mismatch (e.g. 96 kHz tap → 48 kHz WAV)
        //   • Bit-depth mismatch (Int32 → Float32)
        //   • Channel-count mismatch (mono → stereo upmix)
        // Without this step, a tap at 96 kHz written into a 48 kHz WAV plays back
        // at 2× speed (chipmunk) because AVAssetWriter does not resample raw PCM.
        if audioConverter == nil {
            let target = SystemAudioTapEngine.outputFormat
            if let conv = AVAudioConverter(from: deliveryFormat, to: target) {
                audioConverter = conv
                os_log("[SystemAudioTapEngine] Converter created: %.0f Hz %d ch → %.0f Hz %d ch",
                       deliveryFormat.sampleRate, deliveryFormat.channelCount,
                       target.sampleRate, target.channelCount)
            } else {
                os_log("[SystemAudioTapEngine] AVAudioConverter init failed — passing raw buffer")
            }
        }

        let time = AVAudioTime(hostTime: timeStamp.pointee.mHostTime)

        // ── Step 4: convert or pass through ──────────────────────────────────
        if let converter = audioConverter {
            // Allocate output buffer.  Scale frame count by the sample-rate ratio.
            let rateRatio = SystemAudioTapEngine.outputFormat.sampleRate / deliveryFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * rateRatio + 1.0)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: SystemAudioTapEngine.outputFormat,
                                                   frameCapacity: outCapacity) else { return }

            var convError: NSError?
            var inputDone = false
            let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                if inputDone {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                inputDone = true
                return inputBuffer
            }

            if status == .error || outBuffer.frameLength == 0 {
                if let e = convError {
                    os_log("[SystemAudioTapEngine] Converter error: %{public}@", e.localizedDescription)
                }
                return
            }
            bufferHandler(outBuffer, time)
        } else {
            // Converter unavailable — pass through as-is (best-effort).
            bufferHandler(inputBuffer, time)
        }
    }
}

// MARK: - Core Audio property helpers (file-private)

private func tapError(_ operation: String, status: OSStatus) -> Error {
    NSError(domain: "SystemAudioTapEngine", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (OSStatus \(status))"])
}

private func readDefaultSystemOutputDeviceID() throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard err == noErr, deviceID != kAudioObjectUnknown else {
        throw tapError("readDefaultSystemOutputDevice", status: err)
    }
    return deviceID
}

private func readDeviceUID(deviceID: AudioObjectID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    // CFString properties are returned as a retained CFTypeRef; use Unmanaged to safely
    // bridge the pointer without forming an unsafe raw pointer to a Swift object reference.
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    guard err == noErr, let uid else {
        throw tapError("readDeviceUID", status: err)
    }
    return uid.takeRetainedValue() as String
}

private func readTapStreamBasicDescription(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
    guard err == noErr else {
        throw tapError("readTapStreamBasicDescription (kAudioTapPropertyFormat)", status: err)
    }
    return asbd
}
