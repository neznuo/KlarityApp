import Foundation
import Combine
import UserNotifications

// MARK: - HomeViewModel

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    /// Set to the ID of a meeting that was just deleted, so the view can
    /// clear its selection. Reset to nil after the view consumes it.
    @Published var deletedMeetingId: String?

    private var pollTask: Task<Void, Never>?

    var filteredMeetings: [Meeting] {
        if searchText.isEmpty { return meetings }
        let q = searchText.lowercased()
        return meetings.filter { $0.title.lowercased().contains(q) }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            meetings = try await APIClient.shared.fetchMeetings()
            schedulePollingIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Silently refreshes the list without showing the loading spinner.
    /// Used by the background poll task so the UI doesn't flicker.
    private func silentRefresh() async {
        do {
            meetings = try await APIClient.shared.fetchMeetings()
            schedulePollingIfNeeded()
        } catch {
            // Swallow errors during background polling — transient network issues shouldn't show alerts.
        }
    }

    private func schedulePollingIfNeeded() {
        guard meetings.contains(where: { $0.status.needsPolling }) else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.silentRefresh()
            }
        }
    }

    /// Optimistically insert a meeting that was just created so it appears
    /// immediately without waiting for the next network load.
    func insertMeeting(_ meeting: Meeting) {
        if !meetings.contains(where: { $0.id == meeting.id }) {
            meetings.insert(meeting, at: 0)
        }
    }

    func deleteMeeting(_ meeting: Meeting) async {
        do {
            try await APIClient.shared.deleteMeeting(id: meeting.id)
            meetings.removeAll { $0.id == meeting.id }
            deletedMeetingId = meeting.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameMeeting(_ meeting: Meeting, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let updated = try await APIClient.shared.renameMeeting(id: meeting.id, title: trimmed)
            if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
                meetings[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryMeeting(_ meeting: Meeting) async {
        do {
            try await APIClient.shared.triggerProcessing(meetingId: meeting.id)
            await load() // refresh state to show processing spinner
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - RecordingViewModel

@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var meetingTitle: String = ""
    @Published var currentMeeting: Meeting?
    @Published var isCreating = false
    @Published var isStopping = false
    @Published var errorMessage: String?
    /// Set after stopAndProcess() completes. Observers (HomeView) watch this to navigate and refresh.
    @Published var completedMeeting: Meeting?

    let recorder = AudioRecorder()

    private var recorderCancellable: AnyCancellable?
    private var reminderTimer: Timer?

    init() {
        // Forward recorder's published changes so the view re-renders on timer ticks, state changes, etc.
        recorderCancellable = recorder.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isRecording: Bool { recorder.state == .recording }
    var isPaused:    Bool { recorder.state == .paused }
    var isPreparing: Bool { recorder.state == .preparing }
    var hasSysAudio: Bool { recorder.hasSysAudioSource }
    var hasMicAudio: Bool { recorder.hasMicAudioSource }

    func startNewMeeting(calendarEventId: String? = nil, calendarSource: String? = nil) async {
        guard !meetingTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a meeting title."
            return
        }
        
        // Request notifications for the 30-min reminder
        try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        // Guard against concurrent taps: by the time a second Task runs on the main actor,
        // the first task has already set isCreating = true.
        guard !isCreating && recorder.state == .idle else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let meeting = try await APIClient.shared.createMeeting(
                title: meetingTitle,
                calendarEventId: calendarEventId,
                calendarSource: calendarSource
            )
            currentMeeting = meeting
            let audioURL = audioOutputURL(for: meeting.id)
            recorder.startRecording(to: audioURL)
            scheduleReminder()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pauseRecording() {
        recorder.pauseRecording()
    }

    func resumeRecording() {
        recorder.resumeRecording()
    }

    func stopAndProcess() async {
        reminderTimer?.invalidate()
        guard let meeting = currentMeeting else { return }
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        let capturedDuration = recorder.elapsedSeconds > 0 ? recorder.elapsedSeconds : nil
        let fileURL = await recorder.stopRecording()

        do {
            let result: Meeting
            if let path = fileURL?.path {
                let updated = try await APIClient.shared.updateMeeting(
                    id: meeting.id,
                    audioFilePath: path,
                    durationSeconds: capturedDuration
                )
                try await APIClient.shared.triggerProcessing(meetingId: meeting.id)
                result = updated
            } else {
                result = meeting
            }
            currentMeeting = nil
            meetingTitle = ""
            completedMeeting = result   // HomeView observes this to navigate
        } catch {
            errorMessage = error.localizedDescription
            currentMeeting = nil
            meetingTitle = ""
            completedMeeting = meeting
        }
    }

    private func meetingDir(for meetingId: String) -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AI-Meetings/meetings/\(meetingId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func audioOutputURL(for meetingId: String) -> URL {
        meetingDir(for: meetingId).appendingPathComponent("audio.wav")
    }

    private func scheduleReminder() {
        reminderTimer?.invalidate()
        // Fire every 30 mins
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.isRecording || self.isPaused {
                    self.sendNotification()
                }
            }
        }
    }

    private func sendNotification() {
        let mins = Int(recorder.elapsedSeconds) / 60
        NotificationCenter.default.post(
            name: NSNotification.Name("KlarityShowReminder"),
            object: nil,
            userInfo: ["minutes": mins]
        )
    }
}

// MARK: - MeetingDetailViewModel

@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published var meeting: Meeting?
    @Published var transcript: [TranscriptSegment] = []
    @Published var speakers: [SpeakerCluster] = []
    @Published var summary: MeetingSummary?
    @Published var tasks: [MeetingTask] = []
    @Published var people: [Person] = []
    @Published var isLoading = false
    @Published var isRematching = false
    @Published var errorMessage: String?

    /// Derived from the meeting's own status so it stays in sync with polling.
    var isSummarizing: Bool { meeting?.status == .summarizing }

    private var pollingTask: Task<Void, Never>?

    func loadAll(meetingId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let m    = APIClient.shared.fetchMeeting(id: meetingId)
            async let t    = APIClient.shared.fetchTranscript(meetingId: meetingId)
            async let s    = APIClient.shared.fetchSpeakers(meetingId: meetingId)
            async let sum  = APIClient.shared.fetchSummary(meetingId: meetingId)
            async let tk   = APIClient.shared.fetchTasks(meetingId: meetingId)
            async let ppl  = APIClient.shared.fetchPeople()
            (meeting, transcript, speakers, summary, tasks, people) = try await (m, t, s, sum, tk, ppl)
            
            if meeting?.status.needsPolling == true {
                startPolling(meetingId: meetingId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func startPolling(meetingId: String) {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                    guard let self else { return }
                    
                    let updated = try await APIClient.shared.fetchMeeting(id: meetingId)
                    self.meeting = updated
                    
                    if !updated.status.needsPolling {
                        if updated.status == .failed {
                            self.errorMessage = "Processing failed. Check your API keys and try again."
                        } else {
                            // Finished — refresh all derived data
                            self.transcript = (try? await APIClient.shared.fetchTranscript(meetingId: meetingId)) ?? []
                            self.speakers   = (try? await APIClient.shared.fetchSpeakers(meetingId: meetingId)) ?? []
                            self.summary    = try? await APIClient.shared.fetchSummary(meetingId: meetingId)
                            self.tasks      = (try? await APIClient.shared.fetchTasks(meetingId: meetingId)) ?? []
                        }
                        break
                    }
                } catch {
                    // Ignore transient network/polling errors so it keeps trying
                }
            }
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    func renameCurrentMeeting(title: String) async {
        guard let m = meeting else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            meeting = try await APIClient.shared.renameMeeting(id: m.id, title: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryProcessing() async {
        guard let m = meeting else { return }
        do {
            try await APIClient.shared.triggerProcessing(meetingId: m.id)
            await loadAll(meetingId: m.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generateSummary() async {
        guard let meeting else { return }
        do {
            // Fetch live settings so we use whatever provider+model the user has configured
            let currentSettings = try await APIClient.shared.fetchSettings()
            try await APIClient.shared.generateSummary(
                meetingId: meeting.id,
                provider: currentSettings.defaultLlmProvider,
                model: currentSettings.defaultLlmModel
            )
            // Fetch the updated meeting (status will now be "summarizing") then hand off to polling
            self.meeting = try await APIClient.shared.fetchMeeting(id: meeting.id)
            startPolling(meetingId: meeting.id)
        } catch {
            errorMessage = "Failed to start summary: \(error.localizedDescription)"
        }
    }

    func assignSpeaker(cluster: SpeakerCluster, person: Person) async {
        guard let meeting else { return }
        do {
            try await APIClient.shared.assignSpeaker(meetingId: meeting.id, clusterId: cluster.id, personId: person.id)
            transcript = (try? await APIClient.shared.fetchTranscript(meetingId: meeting.id)) ?? transcript
            speakers   = (try? await APIClient.shared.fetchSpeakers(meetingId: meeting.id)) ?? speakers
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAndAssign(cluster: SpeakerCluster, name: String) async {
        guard let meeting else { return }
        do {
            try await APIClient.shared.assignSpeaker(meetingId: meeting.id, clusterId: cluster.id, newPersonName: name)
            transcript = (try? await APIClient.shared.fetchTranscript(meetingId: meeting.id)) ?? transcript
            speakers   = (try? await APIClient.shared.fetchSpeakers(meetingId: meeting.id)) ?? speakers
            people     = (try? await APIClient.shared.fetchPeople()) ?? people
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmSuggestion(cluster: SpeakerCluster) async {
        guard let meeting else { return }
        do {
            try await APIClient.shared.confirmSuggestion(meetingId: meeting.id, clusterId: cluster.id)
            transcript = (try? await APIClient.shared.fetchTranscript(meetingId: meeting.id)) ?? transcript
            speakers   = (try? await APIClient.shared.fetchSpeakers(meetingId: meeting.id)) ?? speakers
            people     = (try? await APIClient.shared.fetchPeople()) ?? people
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissSuggestion(cluster: SpeakerCluster) async {
        guard let meeting else { return }
        do {
            try await APIClient.shared.dismissSuggestion(meetingId: meeting.id, clusterId: cluster.id)
            speakers = (try? await APIClient.shared.fetchSpeakers(meetingId: meeting.id)) ?? speakers
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recomputeSpeakerSuggestions() async {
        guard let meeting else { return }
        isRematching = true
        do {
            try await APIClient.shared.recomputeSpeakerSuggestions(meetingId: meeting.id)
            // Poll until matching completes (status leaves matching_speakers)
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let updated = try? await APIClient.shared.fetchMeeting(id: meeting.id) {
                    self.meeting = updated
                    if updated.status != .matchingSpeakers { break }
                }
            }
            // Refresh speakers and people with the new suggestions
            speakers = (try? await APIClient.shared.fetchSpeakers(meetingId: meeting.id)) ?? speakers
            people   = (try? await APIClient.shared.fetchPeople()) ?? people
            transcript = (try? await APIClient.shared.fetchTranscript(meetingId: meeting.id)) ?? transcript
        } catch {
            errorMessage = error.localizedDescription
        }
        isRematching = false
    }

    func toggleTaskStatus(_ task: MeetingTask) async {
        let newStatus = task.status.lowercased() == "completed" ? "open" : "completed"
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].status = newStatus
        }
        do {
            let updated = try await APIClient.shared.updateTask(taskId: task.id, status: newStatus)
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx].status = task.status
            }
        }
    }

    func updateTaskOwner(task: MeetingTask, personId: String?) async {
        let previousOwnerId = task.ownerPersonId
        let previousOwnerText = task.rawOwnerText

        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            if let pid = personId, !pid.isEmpty {
                let person = people.first { $0.id == pid }
                tasks[idx].ownerPersonId = pid
                tasks[idx].rawOwnerText = person?.displayName
            } else {
                tasks[idx].ownerPersonId = nil
                tasks[idx].rawOwnerText = nil
            }
        }

        do {
            // "" = unassign (backend clears both owner_person_id and raw_owner_text)
            let assignId: String? = if let pid = personId, !pid.isEmpty { pid } else { "" }
            let updated = try await APIClient.shared.updateTask(taskId: task.id, ownerPersonId: assignId)
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx].ownerPersonId = previousOwnerId
                tasks[idx].rawOwnerText = previousOwnerText
            }
        }
    }
}

// MARK: - PeopleViewModel

@MainActor
final class PeopleViewModel: ObservableObject {
    @Published var people: [Person] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { people = try await APIClient.shared.fetchPeople() }
        catch { errorMessage = error.localizedDescription }
    }

    func delete(_ person: Person) async {
        do {
            try await APIClient.shared.deletePerson(id: person.id)
            people.removeAll { $0.id == person.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ person: Person, to name: String) async {
        do {
            let updated = try await APIClient.shared.updatePerson(id: person.id, displayName: name, notes: person.notes)
            if let idx = people.firstIndex(where: { $0.id == person.id }) {
                people[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recomputeEmbedding(_ person: Person) async {
        do {
            try await APIClient.shared.recomputePersonEmbedding(personId: person.id)
            // Reload after a short delay so has_voice_embedding reflects the new file
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - ActionItemsViewModel

@MainActor
enum TaskFilter: String, CaseIterable, Identifiable {
    case mine = "Assigned to Me"
    case all  = "All Tasks"
    var id: String { rawValue }
}

@MainActor
enum StatusFilter: String, CaseIterable, Identifiable {
    case open      = "Open"
    case completed = "Done"
    case all       = "All"
    var id: String { rawValue }
}

@MainActor
final class ActionItemsViewModel: ObservableObject {
    @Published var tasks: [MeetingTask] = []
    @Published var filter: TaskFilter = .mine
    @Published var statusFilter: StatusFilter = .open
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Persisted display name used to match "Assigned to Me"
    @Published var myName: String {
        didSet { UserDefaults.standard.set(myName, forKey: "klarityMyName") }
    }

    init() {
        myName = UserDefaults.standard.string(forKey: "klarityMyName") ?? ""
    }

    /// Tasks visible after applying both the assignee filter and status filter.
    var filteredTasks: [MeetingTask] {
        // 1. Assignee filter
        let assigneeFiltered: [MeetingTask]
        switch filter {
        case .all:
            assigneeFiltered = tasks
        case .mine:
            let name = myName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name.isEmpty {
                assigneeFiltered = tasks
            } else {
                assigneeFiltered = tasks.filter {
                    ($0.rawOwnerText ?? "").lowercased().contains(name)
                }
            }
        }

        // 2. Status filter
        switch statusFilter {
        case .all:       return assigneeFiltered
        case .open:      return assigneeFiltered.filter { $0.status.lowercased() != "completed" }
        case .completed: return assigneeFiltered.filter { $0.status.lowercased() == "completed" }
        }
    }

    /// Tasks grouped by meeting, sorted with most-recent meeting first.
    var tasksByMeeting: [(meetingId: String, title: String, tasks: [MeetingTask])] {
        let grouped = Dictionary(grouping: filteredTasks, by: { $0.meetingId })
        return grouped.map { meetingId, taskList in
            let title = taskList.first?.meetingTitle ?? "Meeting"
            return (meetingId: meetingId, title: title, tasks: taskList)
        }
        .sorted { a, b in
            let aDate = a.tasks.first?.status ?? ""  // keep ordering stable by using first task
            let _ = aDate
            // Sort by the first task's position in the original (desc by created_at) array
            let aPos = tasks.firstIndex(where: { $0.meetingId == a.meetingId }) ?? Int.max
            let bPos = tasks.firstIndex(where: { $0.meetingId == b.meetingId }) ?? Int.max
            return aPos < bPos
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tasks = try await APIClient.shared.fetchGlobalTasks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleTaskStatus(_ task: MeetingTask) async {
        let newStatus = task.status.lowercased() == "completed" ? "open" : "completed"
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].status = newStatus
        }
        do {
            let updated = try await APIClient.shared.updateTask(taskId: task.id, status: newStatus)
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx].status = task.status
            }
        }
    }

    func deleteTask(_ task: MeetingTask) async {
        tasks.removeAll { $0.id == task.id }
        do {
            try await APIClient.shared.deleteTask(taskId: task.id)
        } catch {
            errorMessage = error.localizedDescription
            // Re-load to restore state if delete failed
            await load()
        }
    }

    func updateTaskOwner(_ task: MeetingTask, newOwner: String) async {
        // Optimistic update
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].rawOwnerText = newOwner.isEmpty ? nil : newOwner
        }
        do {
            let updated = try await APIClient.shared.updateTask(taskId: task.id, ownerText: newOwner)
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
            await load()
        }
    }
}

// MARK: - SettingsViewModel

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings = .default
    @Published var ollamaModels: [String] = []
    @Published var isLoadingOllamaModels = false
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await APIClient.shared.fetchSettings()
            if settings.defaultLlmProvider == "ollama" {
                await loadOllamaModels()
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func loadOllamaModels() async {
        isLoadingOllamaModels = true
        defer { isLoadingOllamaModels = false }
        ollamaModels = (try? await APIClient.shared.fetchOllamaModels()) ?? []
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(settings)
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            settings = try await APIClient.shared.updateSettings(dict)
            // Also persist sensitive keys to Keychain
            KeychainService.save(key: KeychainService.elevenLabsKey, value: settings.elevenLabsApiKey)
            KeychainService.save(key: KeychainService.openAIKey, value: settings.openAiApiKey)
            KeychainService.save(key: KeychainService.anthropicKey, value: settings.anthropicApiKey)
            KeychainService.save(key: KeychainService.geminiKey, value: settings.geminiApiKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendTestNotification() {
        NotificationCenter.default.post(
            name: NSNotification.Name("KlarityShowReminder"),
            object: nil,
            userInfo: ["minutes": 30, "isTest": true]
        )
    }
}

// MARK: - PermissionsViewModel

import AVFoundation
import CoreGraphics
import AppKit

@MainActor
final class PermissionsViewModel: ObservableObject {
    @Published var hasMicAccess = false
    // System audio capture via Core Audio Tap does not have a pre-flight API.
    // The permission prompt appears the first time AudioHardwareCreateProcessTap is called.
    // We infer "granted" from whether the last recording actually received audio.
    @Published var hasSystemAudioAccess: Bool? = nil   // nil = unknown (never recorded)

    init() {
        checkPermissions()
    }

    func checkPermissions() {
        hasMicAccess = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.hasMicAccess = granted
            }
        }
    }

    /// Call this after a recording attempt. `receivedAudio` is true if the tap
    /// delivered non-silence — which confirms system audio permission was granted.
    func updateSystemAudioStatus(receivedAudio: Bool) {
        hasSystemAudioAccess = receivedAudio
    }

    func resetPermissions() {
        // macOS 14+ caches TCC database states in memory for actively running applications.
        // If an app asks to reset its *own* permissions while running, macOS silently ignores it.
        // We must terminate the app first, then run tccutil from a detached background script.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.klarity.meeting-assistant"
        let bundlePath = Bundle.main.bundlePath

        let script = """
        sleep 1
        /usr/bin/tccutil reset All \(bundleID)
        open "\(bundlePath)"
        """

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script]
        try? relaunch.run()

        // Quit the app immediately so the script can execute the reset while we are dead
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - CalendarViewModel

@MainActor
final class CalendarViewModel: ObservableObject {
    @Published var upcomingEvents: [CalendarEvent] = []
    @Published var isLoadingEvents = false

    var hasAnyCalendarConnected: Bool {
        CalendarService.shared.isConnected(.google) || CalendarService.shared.isConnected(.microsoft)
    }

    func loadEvents() async {
        guard hasAnyCalendarConnected else { return }
        isLoadingEvents = true
        defer { isLoadingEvents = false }
        upcomingEvents = await CalendarService.shared.fetchAllEvents()
    }
}

// MARK: - UpcomingViewModel

@MainActor
final class UpcomingViewModel: ObservableObject {
    @Published var upcomingEvents: [CalendarEvent] = []
    @Published var isLoadingEvents = false
    @Published var errorMessage: String?

    var hasAnyCalendarConnected: Bool {
        CalendarService.shared.isConnected(.google) || CalendarService.shared.isConnected(.microsoft)
    }

    private var refreshTimer: Timer?
    private var lastFetchTime: Date?

    func loadEvents() async {
        guard hasAnyCalendarConnected else {
            upcomingEvents = []
            return
        }
        // Skip refetch if data is fresh (< 5 min old)
        if let last = lastFetchTime, Date().timeIntervalSince(last) < 300, !upcomingEvents.isEmpty {
            return
        }
        await forceLoadEvents()
    }

    func forceLoadEvents() async {
        guard hasAnyCalendarConnected else {
            upcomingEvents = []
            return
        }
        isLoadingEvents = true
        defer { isLoadingEvents = false }
        do {
            upcomingEvents = try await CalendarService.shared.fetchAllEventsThrowing()
            lastFetchTime = Date()
            errorMessage = nil
        } catch {
            if upcomingEvents.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.forceLoadEvents()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func joinMeeting(url: URL) {
        NSWorkspace.shared.open(url)
    }

    func recordOnly(event: CalendarEvent, recordingVM: RecordingViewModel) async {
        recordingVM.meetingTitle = event.title
        await recordingVM.startNewMeeting(
            calendarEventId: event.id,
            calendarSource: event.calendarSource.rawValue
        )
    }

    func joinAndRecord(event: CalendarEvent, recordingVM: RecordingViewModel) async {
        if let urlStr = event.onlineMeetingUrl, let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
        recordingVM.meetingTitle = event.title
        await recordingVM.startNewMeeting(
            calendarEventId: event.id,
            calendarSource: event.calendarSource.rawValue
        )
    }
}
