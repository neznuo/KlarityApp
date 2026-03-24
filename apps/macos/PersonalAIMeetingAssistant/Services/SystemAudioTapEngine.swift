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
///  5. Converts each buffer to `AVAudioPCMBuffer` (with a data copy) and calls the handler.
@available(macOS 14.2, *)
final class SystemAudioTapEngine {
    typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let bufferHandler: BufferHandler
    private var processTapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    private let queue = DispatchQueue(label: "com.klarity.systemAudioTap", qos: .userInitiated)

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
            self?.handleAudio(bufferList: inInputData, timeStamp: inInputTime, format: tapFormat)
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

        os_log("[SystemAudioTapEngine] Stopped")
    }

    deinit { stop() }

    // MARK: - IOProc callback

    private func handleAudio(bufferList: UnsafePointer<AudioBufferList>,
                              timeStamp: UnsafePointer<AudioTimeStamp>,
                              format: AVAudioFormat) {
        // Wrap the IOProc buffer without copying (no-copy), then immediately copy it into
        // a new owning buffer so the data safely outlives this IOProc invocation when the
        // buffer handler dispatches it asynchronously.
        guard let noCopy = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil),
              let buffer = noCopy.copy() as? AVAudioPCMBuffer else { return }

        let time = AVAudioTime(hostTime: timeStamp.pointee.mHostTime)
        bufferHandler(buffer, time)
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
