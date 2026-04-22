import Foundation
import AppKit
import os.log
import CoreAudio
import ApplicationServices

@MainActor
final class MeetingDetectorService: ObservableObject {
    static let shared = MeetingDetectorService()

    @Published var detectedMeeting: DetectedMeeting?

    private let logger = AppLogger(category: "MeetingDetector")

    // Settings (persisted via UserDefaults)
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: "klarityMeetingDetection") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "klarityMeetingDetection")
            if isEnabled { start() } else { stop() }
        }
    }
    @Published var detectCalendar: Bool = UserDefaults.standard.object(forKey: "klarityDetectCalendar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(detectCalendar, forKey: "klarityDetectCalendar") }
    }
    @Published var detectCalls: Bool = UserDefaults.standard.object(forKey: "klarityDetectCalls") as? Bool ?? true {
        didSet { UserDefaults.standard.set(detectCalls, forKey: "klarityDetectCalls") }
    }
    @Published var leadTime: NotificationLeadTime = NotificationLeadTime(rawValue: UserDefaults.standard.integer(forKey: "klarityLeadTime")) ?? .twoMinutes {
        didSet { UserDefaults.standard.set(leadTime.rawValue, forKey: "klarityLeadTime") }
    }

    // Dedup — tracks which meeting IDs we've already notified about
    private var notifiedIDs: Set<String> = []
    private var lastNotificationTime: Date?

    // Timers
    private var calendarTimer: Timer?
    private var windowTitleTimer: Timer?

    // Cached calendar events
    private var upcomingEvents: [CalendarEvent] = []

    // Audio device signal
    private static let audioDevicePatterns: [AudioDevicePattern] = [
        AudioDevicePattern(nameContains: "ZoomAudioDevice", appName: "Zoom"),
        AudioDevicePattern(nameContains: "Microsoft Teams Audio", appName: "Microsoft Teams"),
        AudioDevicePattern(nameContains: "Ecamm Live Audio", appName: "Ecamm Live"),
    ]
    private var audioDeviceListenerInstalled = false
    private var knownDeviceUIDs: Set<String> = []

    // Window title signal
    private static let windowTitlePatterns: [WindowTitlePattern] = [
        WindowTitlePattern(appName: "FaceTime", titleMustContain: ["FaceTime"], titleAnyOf: ["Call", "Audio", "Video"]),
        WindowTitlePattern(appName: "WhatsApp", titleMustContain: ["WhatsApp"], titleAnyOf: ["Video", "Audio"]),
        WindowTitlePattern(appName: "Google Meet", titleMustContain: ["Meet - "], titleAnyOf: []),
        WindowTitlePattern(appName: "Google Meet", titleMustContain: ["meet.google.com"], titleAnyOf: []),
        WindowTitlePattern(appName: "Zoom", titleMustContain: ["Zoom Meeting"], titleAnyOf: []),
        WindowTitlePattern(appName: "Microsoft Teams", titleMustContain: ["Microsoft Teams"], titleAnyOf: ["Call", "Meeting"]),
        WindowTitlePattern(appName: "Slack", titleMustContain: ["Slack"], titleAnyOf: ["Huddle", "Call"]),
    ]
    var isAccessibilityGranted: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    init() {
        if isEnabled {
            // Deferred to next runloop so @Published observers are ready
            DispatchQueue.main.async { self.start() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        logger.info("Meeting detection started")
        notifiedIDs.removeAll()
        checkCalendarSignal()
        startCalendarTimer()
        startAudioDeviceListener()
        startWindowTitlePolling()
    }

    func stop() {
        logger.info("Meeting detection stopped")
        calendarTimer?.invalidate()
        calendarTimer = nil
        windowTitleTimer?.invalidate()
        windowTitleTimer = nil
        stopAudioDeviceListener()
        detectedMeeting = nil
        notifiedIDs.removeAll()
    }

    // MARK: - Calendar Signal

    private func startCalendarTimer() {
        calendarTimer?.invalidate()
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkCalendarSignal() }
        }
    }

    func checkCalendarSignal() {
        guard detectCalendar else { return }
        guard CalendarService.shared.isConnected(.google) || CalendarService.shared.isConnected(.microsoft) else { return }

        Task {
            upcomingEvents = await CalendarService.shared.fetchAllEvents()
            let now = Date()
            let leadSeconds = Double(leadTime.rawValue) * 60

            for event in upcomingEvents {
                let timeUntilStart = event.startDate.timeIntervalSince(now)
                // Event starts within the lead time window (0 to leadSeconds ahead)
                if timeUntilStart > 0 && timeUntilStart <= leadSeconds && event.onlineMeetingUrl != nil {
                    let meetingID = event.id
                    if !notifiedIDs.contains(meetingID) {
                        notifiedIDs.insert(meetingID)
                        let detected = DetectedMeeting(
                            source: .calendar,
                            appName: appNameFromURL(event.onlineMeetingUrl),
                            meetingTitle: event.title,
                            onlineMeetingUrl: event.onlineMeetingUrl,
                            calendarEventId: event.id,
                            calendarSource: event.calendarSource.rawValue
                        )
                        fireDetection(detected)
                    }
                }
            }
        }
    }

    private func appNameFromURL(_ url: String?) -> String {
        guard let url else { return "Calendar" }
        if url.contains("zoom.us") { return "Zoom" }
        if url.contains("meet.google") { return "Google Meet" }
        if url.contains("teams.microsoft") { return "Microsoft Teams" }
        if url.contains("webex.com") { return "Webex" }
        return "Calendar"
    }

    // MARK: - Audio Device Signal

    func startAudioDeviceListener() {
        guard detectCalls else { return }
        guard !audioDeviceListenerInstalled else { return }

        // Snapshot current devices
        knownDeviceUIDs = currentAudioDeviceUIDs()

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, klarityDeviceListChangedCallback, selfPtr)
        if status == noErr {
            audioDeviceListenerInstalled = true
            logger.info("Audio device listener installed")
        } else {
            logger.error("Failed to install audio device listener: \(status)")
        }
    }

    func stopAudioDeviceListener() {
        guard audioDeviceListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, klarityDeviceListChangedCallback, selfPtr)
        audioDeviceListenerInstalled = false
        logger.info("Audio device listener removed")
    }

    private func currentAudioDeviceUIDs() -> Set<String> {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)

        var uids: Set<String> = []
        for id in ids {
            var uidSize = UInt32(0)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyDataSize(id, &uidAddr, 0, nil, &uidSize)
            var cfUID: Unmanaged<CFString>?
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &cfUID)
            if let uid = cfUID?.takeUnretainedValue() as? String {
                uids.insert(uid)
            }
        }
        return uids
    }

    /// Called from the Core Audio callback when the device list changes.
    func handleDeviceListChange() {
        let newUIDs = currentAudioDeviceUIDs()
        let added = newUIDs.subtracting(knownDeviceUIDs)
        knownDeviceUIDs = newUIDs

        guard !added.isEmpty else { return }

        // Check if any new device matches a known meeting app
        for deviceID in added {
            if let deviceName = deviceNameForUID(deviceID) {
                for pattern in Self.audioDevicePatterns {
                    if deviceName.contains(pattern.nameContains) {
                        let meetingID = "\(pattern.appName)-\(Int(Date().timeIntervalSince1970 / 300))"
                        if !notifiedIDs.contains(meetingID) {
                            notifiedIDs.insert(meetingID)
                            let detected = DetectedMeeting(
                                source: .audioDevice,
                                appName: pattern.appName,
                                meetingTitle: "\(pattern.appName) Meeting"
                            )
                            fireDetection(detected)
                        }
                        return
                    }
                }
            }
        }
    }

    private func deviceNameForUID(_ uid: String) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)

        for id in ids {
            var uidSize = UInt32(0)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyDataSize(id, &uidAddr, 0, nil, &uidSize)
            var cfUID: Unmanaged<CFString>?
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &cfUID)
            if let dUID = cfUID?.takeUnretainedValue() as? String, dUID == uid {
                var nameSize = UInt32(0)
                var nameAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceNameCFString,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectGetPropertyDataSize(id, &nameAddr, 0, nil, &nameSize)
                var cfName: Unmanaged<CFString>?
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &cfName)
                return cfName?.takeUnretainedValue() as? String
            }
        }
        return nil
    }

    // MARK: - Window Title Signal

    private func startWindowTitlePolling() {
        guard detectCalls else { return }
        windowTitleTimer?.invalidate()
        windowTitleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkWindowTitleSignal() }
        }
    }

    func checkWindowTitleSignal() {
        guard detectCalls, isAccessibilityGranted else { return }

        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier

            let axApp = AXUIElementCreateApplication(pid)
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)

            guard result == .success, let windows = value as? [AXUIElement] else { continue }

            for window in windows {
                var titleValue: AnyObject?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                guard let title = titleValue as? String, !title.isEmpty else { continue }

                for pattern in Self.windowTitlePatterns {
                    if pattern.matches(title) {
                        let meetingID = "\(pattern.appName)-\(Int(Date().timeIntervalSince1970 / 300))"
                        if !notifiedIDs.contains(meetingID) {
                            notifiedIDs.insert(meetingID)
                            let detected = DetectedMeeting(
                                source: .windowTitle,
                                appName: pattern.appName,
                                meetingTitle: title
                            )
                            fireDetection(detected)
                        }
                        return
                    }
                }
            }
        }
    }

    /// Opens System Preferences > Accessibility so the user can grant access.
    func openAccessibilityPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Fire Detection (with debouncing)

    private func fireDetection(_ meeting: DetectedMeeting) {
        let now = Date()
        if let last = lastNotificationTime, now.timeIntervalSince(last) < 30 {
            logger.info("Debounced detection for \(meeting.appName)")
            return
        }
        lastNotificationTime = now
        detectedMeeting = meeting
        logger.info("Meeting detected: \(meeting.appName) — \(meeting.meetingTitle)")
        NotificationCenter.default.post(name: NSNotification.Name("KlarityMeetingDetected"), object: nil)
    }

    /// Called by the UI after the user acts on (or dismisses) the notification.
    func clearDetection() {
        detectedMeeting = nil
    }
}

// MARK: - Core Audio Device List Changed Callback

private func klarityDeviceListChangedCallback(objectID: AudioObjectID, numAddresses: UInt32, addresses: UnsafePointer<AudioObjectPropertyAddress>, data: UnsafeMutableRawPointer?) -> Int32 {
    guard let data else { return noErr }
    let service = Unmanaged<MeetingDetectorService>.fromOpaque(data).takeUnretainedValue()
    Task { @MainActor in
        service.handleDeviceListChange()
    }
    return noErr
}