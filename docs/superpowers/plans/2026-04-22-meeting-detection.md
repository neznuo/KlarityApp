# Meeting Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a MeetingDetectorService that combines calendar polling, audio device monitoring, and window title inspection to detect meetings in real-time and show an in-app notification under the menu bar icon prompting the user to start recording.

**Architecture:** A new `MeetingDetectorService` singleton held by `AppState` runs three signals (calendar poll, Core Audio device listener, window title poll) and publishes a `DetectedMeeting`. The `MenuBarManager` observes it and shows a reminder-style popover (matching the existing recording reminder pattern). Settings toggles control which signals are active.

**Tech Stack:** Swift/SwiftUI, Core Audio HAL API, Accessibility API (AXUIElement), NSWorkspace, UserDefaults

---

### Task 1: Create DetectedMeeting model and MeetingSignalPattern

**Files:**
- Create: `apps/macos/PersonalAIMeetingAssistant/Models/MeetingDetectionModels.swift`

- [ ] **Step 1: Create the model file**

```swift
import Foundation

// MARK: - Detected Meeting

enum MeetingDetectionSource: String {
    case calendar
    case audioDevice
    case windowTitle
}

struct DetectedMeeting: Identifiable {
    let id: String
    let source: MeetingDetectionSource
    let appName: String
    let meetingTitle: String
    let onlineMeetingUrl: String?
    let calendarEventId: String?
    let calendarSource: String?

    init(source: MeetingDetectionSource, appName: String, meetingTitle: String,
         onlineMeetingUrl: String? = nil, calendarEventId: String? = nil, calendarSource: String? = nil) {
        self.id = calendarEventId ?? "\(appName)-\(Int(Date().timeIntervalSince1970 / 300))"
        self.source = source
        self.appName = appName
        self.meetingTitle = meetingTitle
        self.onlineMeetingUrl = onlineMeetingUrl
        self.calendarEventId = calendarEventId
        self.calendarSource = calendarSource
    }
}

// MARK: - Signal Patterns

struct AudioDevicePattern {
    let nameContains: String
    let appName: String
}

struct WindowTitlePattern {
    let appName: String
    let titleMustContain: [String]  // ALL must be present
    let titleAnyOf: [String]         // AT LEAST ONE must be present

    func matches(_ title: String) -> Bool {
        let lower = title.lowercased()
        let allPresent = titleMustContain.allSatisfy { lower.contains($0.lowercased()) }
        let anyPresent = titleAnyOf.isEmpty || titleAnyOf.contains { lower.contains($0.lowercased()) }
        return allPresent && anyPresent
    }
}

// MARK: - Notification Lead Time

enum NotificationLeadTime: Int, CaseIterable {
    case oneMinute = 1
    case twoMinutes = 2
    case fiveMinutes = 5

    var label: String {
        switch self {
        case .oneMinute: return "1 min"
        case .twoMinutes: return "2 min"
        case .fiveMinutes: return "5 min"
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/Models/MeetingDetectionModels.swift
git commit -m "feat(detection): add DetectedMeeting model and signal pattern types"
```

---

### Task 2: Create MeetingDetectorService — calendar signal

**Files:**
- Create: `apps/macos/PersonalAIMeetingAssistant/Services/MeetingDetectorService.swift`

- [ ] **Step 1: Create the service with calendar signal only**

```swift
import Foundation
import os.log

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

    private init() {
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
    }

    func stop() {
        logger.info("Meeting detection stopped")
        calendarTimer?.invalidate()
        calendarTimer = nil
        windowTitleTimer?.invalidate()
        windowTitleTimer = nil
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
    }

    /// Called by the UI after the user acts on (or dismisses) the notification.
    func clearDetection() {
        detectedMeeting = nil
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/Services/MeetingDetectorService.swift
git commit -m "feat(detection): add MeetingDetectorService with calendar signal"
```

---

### Task 3: Add audio device signal to MeetingDetectorService

**Files:**
- Modify: `apps/macos/PersonalAIMeetingAssistant/Services/MeetingDetectorService.swift`

- [ ] **Step 1: Add audio device patterns and Core Audio listener**

Add these properties to the class (after `private var upcomingEvents`):

```swift
    // Audio device signal
    private static let audioDevicePatterns: [AudioDevicePattern] = [
        AudioDevicePattern(nameContains: "ZoomAudioDevice", appName: "Zoom"),
        AudioDevicePattern(nameContains: "Microsoft Teams Audio", appName: "Microsoft Teams"),
        AudioDevicePattern(nameContains: "Ecamm Live Audio", appName: "Ecamm Live"),
    ]
    private var audioDeviceListenerInstalled = false
    private var knownDeviceUIDs: Set<String> = []
```

Add these methods (before `fireDetection`):

```swift
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
```

Also add the free function callback at the **bottom of the file** (outside the class):

```swift
// MARK: - Core Audio Device List Changed Callback

private func klarityDeviceListChangedCallback(objectID: AudioObjectID, numAddresses: UInt32, addresses: UnsafePointer<AudioObjectPropertyAddress>, data: UnsafeMutableRawPointer?) -> Int32 {
    guard let data else { return noErr }
    let service = Unmanaged<MeetingDetectorService>.fromOpaque(data).takeUnretainedValue()
    Task { @MainActor in
        service.handleDeviceListChange()
    }
    return noErr
}
```

Update `start()` to call the audio device listener:

```swift
    func start() {
        logger.info("Meeting detection started")
        notifiedIDs.removeAll()
        checkCalendarSignal()
        startCalendarTimer()
        startAudioDeviceListener()
    }
```

Note: `startWindowTitlePolling()` will be added in Task 4 when the window title signal is implemented.

Update `stop()` to call the audio device listener removal:

```swift
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
```

Add `import CoreAudio` at the top of the file.

- [ ] **Step 2: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/Services/MeetingDetectorService.swift
git commit -m "feat(detection): add audio device signal to MeetingDetectorService"
```

---

### Task 4: Add window title signal to MeetingDetectorService

**Files:**
- Modify: `apps/macos/PersonalAIMeetingAssistant/Services/MeetingDetectorService.swift`

- [ ] **Step 1: Add window title patterns and polling**

Add these properties after the audio device properties:

```swift
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
    private var isAccessibilityGranted: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
```

Add these methods (before `fireDetection`):

```swift
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
```

Also update `start()` to include window title polling (it was left out of Task 3 for compile-order reasons):

```swift
    func start() {
        logger.info("Meeting detection started")
        notifiedIDs.removeAll()
        checkCalendarSignal()
        startCalendarTimer()
        startAudioDeviceListener()
        startWindowTitlePolling()
    }
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/Services/MeetingDetectorService.swift
git commit -m "feat(detection): add window title signal to MeetingDetectorService"
```

---

### Task 5: Integrate MeetingDetectorService into AppState

**Files:**
- Modify: `apps/macos/PersonalAIMeetingAssistant/App/KlarityApp.swift` (AppState class, ~line 62)

- [ ] **Step 1: Add meetingDetector property to AppState**

Add this property to `AppState` (after `@Published var triggerNewRecording`):

```swift
    let meetingDetector = MeetingDetectorService()
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/App/KlarityApp.swift
git commit -m "feat(detection): integrate MeetingDetectorService into AppState"
```

---

### Task 6: Add meeting detection notification to MenuBarManager

**Files:**
- Modify: `apps/macos/PersonalAIMeetingAssistant/Features/MenuBar/MenuBarView.swift`

- [ ] **Step 1: Add a meeting detection listener to MenuBarManager.setup**

In `MenuBarManager.setup(appState:recordingVM:)`, store a weak reference to `appState` and add a notification observer after the existing `notificationTask`:

```swift
    private weak var appState: AppState?
```

Update `setup` to save the reference and add meeting detection observation:

```swift
    func setup(appState: AppState, recordingVM: RecordingViewModel) {
        self.appState = appState
        self.recordingVM = recordingVM
        let shouldShow = UserDefaults.standard.object(forKey: "klarityShowMenuBar") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "klarityShowMenuBar")
        if shouldShow {
            install(appState: appState, recordingVM: recordingVM)
        }

        // Listen for recording reminder triggers
        notificationTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: NSNotification.Name("KlarityShowReminder")) {
                let isTest = notification.userInfo?["isTest"] as? Bool ?? false
                let isActive = self?.recordingVM?.isRecording == true || self?.recordingVM?.isPaused == true
                if isActive || isTest {
                    let mins = notification.userInfo?["minutes"] as? Int ?? 30
                    await self?.showReminder(minutes: mins)
                }
            }
        }

        // Listen for meeting detection
        meetingDetectionTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSNotification.Name("KlarityMeetingDetected")) {
                guard let meeting = self?.appState?.meetingDetector.detectedMeeting else { return }
                self?.showMeetingNotification(meeting)
            }
        }
    }
```

Also add the `meetingDetectionTask` property alongside the existing `notificationTask`:

```swift
    private var meetingDetectionTask: Task<Void, Never>?
```

- [ ] **Step 2: Add the meeting notification popover method**

Add this method to `MenuBarManager` (after `showReminder`):

```swift
    private func showMeetingNotification(_ meeting: DetectedMeeting) {
        if popover?.isShown == true { return }
        guard let button = statusItem?.button else { return }

        if reminderPopover == nil {
            let pop = NSPopover()
            pop.behavior = .transient
            self.reminderPopover = pop
        }

        let sourceIcon: String
        switch meeting.source {
        case .calendar: sourceIcon = "calendar"
        case .audioDevice: sourceIcon = "speaker.wave.2.fill"
        case .windowTitle: sourceIcon = "app.badge"
        }

        let sourceLabel = meeting.source == .calendar ? "Meeting Starting" : "Meeting Detected"

        let root = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
                    .font(.system(size: 14))
                Text("\(sourceLabel) — \(meeting.appName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(NSColor.labelColor))
            }
            Text(meeting.meetingTitle)
                .font(.system(size: 12))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .lineLimit(2)

            HStack(spacing: 12) {
                Button("Start Recording") {
                    self.reminderPopover?.performClose(nil)
                    self?.appState?.meetingDetector.clearDetection()
                    self?.openMainWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self?.appState?.triggerNewRecording = true
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppTheme.Colors.brandPrimary)

                Button("Dismiss") {
                    self.reminderPopover?.performClose(nil)
                    self?.appState?.meetingDetector.clearDetection()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.blue)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 240)

        reminderPopover?.contentViewController = NSHostingController(rootView: root)
        reminderPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSSound(named: "Glass")?.play()
    }
```

Fix: replace `self?.` inside the button closures with proper weak self capture. The full `showMeetingNotification` should use `[weak self]` captures in the buttons:

```swift
    private func showMeetingNotification(_ meeting: DetectedMeeting) {
        if popover?.isShown == true { return }
        guard let button = statusItem?.button else { return }

        if reminderPopover == nil {
            let pop = NSPopover()
            pop.behavior = .transient
            self.reminderPopover = pop
        }

        let sourceIcon: String
        switch meeting.source {
        case .calendar: sourceIcon = "calendar"
        case .audioDevice: sourceIcon = "speaker.wave.2.fill"
        case .windowTitle: sourceIcon = "app.badge"
        }

        let sourceLabel = meeting.source == .calendar ? "Meeting Starting" : "Meeting Detected"

        let root = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
                    .font(.system(size: 14))
                Text("\(sourceLabel) — \(meeting.appName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(NSColor.labelColor))
            }
            Text(meeting.meetingTitle)
                .font(.system(size: 12))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .lineLimit(2)

            HStack(spacing: 12) {
                Button {
                    self.reminderPopover?.performClose(nil)
                    self.appState?.meetingDetector.clearDetection()
                    self.openMainWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.appState?.triggerNewRecording = true
                    }
                } label: {
                    Text("Start Recording")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.brandPrimary)
                }
                .buttonStyle(.plain)

                Button {
                    self.reminderPopover?.performClose(nil)
                    self.appState?.meetingDetector.clearDetection()
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 240)

        reminderPopover?.contentViewController = NSHostingController(rootView: root)
        reminderPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSSound(named: "Glass")?.play()
    }
```

- [ ] **Step 3: Post a notification when a meeting is detected**

In `MeetingDetectorService.fireDetection`, after setting `detectedMeeting`, post a notification so MenuBarManager picks it up:

```swift
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
```

- [ ] **Step 4: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/Features/MenuBar/MenuBarView.swift apps/macos/PersonalAIMeetingAssistant/Services/MeetingDetectorService.swift
git commit -m "feat(detection): add meeting notification popover to menu bar"
```

---

### Task 7: Add Meeting Detection settings section

**Files:**
- Modify: `apps/macos/PersonalAIMeetingAssistant/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Add Meeting Detection section**

Add this section in SettingsView, after the "Calendar Sync" section (after line 155) and before the "Storage" section:

```swift
            Section {
                Toggle("Enable meeting detection", isOn: Binding(
                    get: { appState.meetingDetector.isEnabled },
                    set: { appState.meetingDetector.isEnabled = $0 }
                ))
                .help("When enabled, Klarity monitors for upcoming meetings and shows a notification to start recording.")

                Toggle("Detect calendar meetings", isOn: Binding(
                    get: { appState.meetingDetector.detectCalendar },
                    set: { appState.meetingDetector.detectCalendar = $0 }
                ))
                .disabled(!appState.meetingDetector.isEnabled || !(CalendarService.shared.isConnected(.google) || CalendarService.shared.isConnected(.microsoft)))

                Toggle("Detect audio/video calls", isOn: Binding(
                    get: { appState.meetingDetector.detectCalls },
                    set: { appState.meetingDetector.detectCalls = $0 }
                ))
                .disabled(!appState.meetingDetector.isEnabled)

                if appState.meetingDetector.detectCalls && !appState.meetingDetector.isAccessibilityGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Accessibility access required for call detection")
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Grant Access") {
                            appState.meetingDetector.openAccessibilityPreferences()
                        }
                        .font(AppTheme.Fonts.caption)
                    }
                }

                Picker("Notify before meeting", selection: Binding(
                    get: { appState.meetingDetector.leadTime },
                    set: { appState.meetingDetector.leadTime = $0 }
                )) {
                    ForEach(NotificationLeadTime.allCases, id: \.rawValue) { lt in
                        Text(lt.label).tag(lt)
                    }
                }
                .disabled(!appState.meetingDetector.isEnabled || !appState.meetingDetector.detectCalendar)

                Button {
                    // Trigger a manual detection check for testing
                    appState.meetingDetector.checkCalendarSignal()
                    appState.meetingDetector.checkWindowTitleSignal()
                } label: {
                    Label("Test Meeting Detection", systemImage: "bell.fill")
                }
                .disabled(!appState.meetingDetector.isEnabled)
                .help("Manually trigger a detection check to test the notification.")
            } header: {
                Text("Meeting Detection")
            } footer: {
                Text("Klarity monitors for upcoming meetings via your connected calendars and detects active calls through audio device changes and window titles (requires Accessibility access).")
                    .foregroundStyle(.secondary)
            }
```

Note: The `isAccessibilityGranted` property is on `MeetingDetectorService` but is not `@Published` since it's computed from the AX API. The settings view reads it directly. For it to update when the user grants permission, we can add a simple check on appear.

- [ ] **Step 2: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/Features/Settings/SettingsView.swift
git commit -m "feat(detection): add Meeting Detection settings section"
```

---

### Task 8: Add new files to Xcode project and verify build

**Files:**
- Modify: `apps/macos/KlarityApp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the new model and service files to the Xcode project**

Open the project in Xcode, right-click the Models group > Add Files, add `MeetingDetectionModels.swift`. Right-click the Services group > Add Files, add `MeetingDetectorService.swift`. Alternatively, use the `patch_pbx.py` script pattern or manually add the file references.

If using Xcode UI: File > Add Files to "PersonalAIMeetingAssistant" > select both new .swift files > ensure "Copy items if needed" is unchecked and the target is checked.

- [ ] **Step 2: Build and verify**

Run: Build in Xcode (Cmd+B)
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/KlarityApp.xcodeproj/project.pbxproj
git commit -m "feat(detection): add new files to Xcode project"
```

---

### Task 9: Manual integration test

**Files:**
- No new files

- [ ] **Step 1: Start the backend**

Run: `cd backend && source venv/bin/activate && uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload`

- [ ] **Step 2: Build and run the frontend in Xcode**

Press Cmd+R in Xcode.

- [ ] **Step 3: Test settings**

1. Open Settings.
2. Verify "Meeting Detection" section appears.
3. Toggle "Enable meeting detection" on.
4. Verify "Detect calendar meetings" and "Detect audio/video calls" toggles are available.
5. If Accessibility is not granted, verify "Grant Access" link appears.
6. Click "Test Meeting Detection" — verify the notification popover appears under the menu bar icon.

- [ ] **Step 4: Test menu bar notification**

1. Click the menu bar icon to verify the normal menu appears.
2. Trigger a meeting detection (via test button or by opening a Zoom/Meet call).
3. Verify a notification popover appears under the menu bar icon with:
   - Correct app name and meeting title
   - "Start Recording" and "Dismiss" buttons
4. Click "Start Recording" — verify the recording sheet opens.
5. Dismiss the recording sheet, trigger detection again.
6. Click "Dismiss" — verify the popover closes and no duplicate notification appears within 30 seconds.