import Foundation
import Combine

// MARK: - HomeViewModel

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""

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
        } catch {
            errorMessage = error.localizedDescription
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
    @Published var recordingMode: RecordingMode = .systemAudioOnly
    @Published var currentMeeting: Meeting?
    @Published var isCreating = false
    @Published var isStopping = false
    @Published var errorMessage: String?

    let recorder = AudioRecorder()

    private var recorderCancellable: AnyCancellable?

    init() {
        // Forward recorder's published changes so the view re-renders on timer ticks, state changes, etc.
        recorderCancellable = recorder.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isRecording: Bool { recorder.state == .recording }
    var isPaused:    Bool { recorder.state == .paused }

    func startNewMeeting() async {
        guard !meetingTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a meeting title."
            return
        }
        // Guard against concurrent taps: by the time a second Task runs on the main actor,
        // the first task has already set isCreating = true.
        guard !isCreating && recorder.state == .idle else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let meeting = try await APIClient.shared.createMeeting(title: meetingTitle)
            currentMeeting = meeting
            let audioURL = audioOutputURL(for: meeting.id)
            let videoURL = recordingMode == .screenAndSystemAudio ? videoOutputURL(for: meeting.id) : nil
            recorder.startRecording(to: audioURL, videoURL: videoURL, mode: recordingMode)
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

    func stopAndProcess() async -> Meeting? {
        guard let meeting = currentMeeting else { return nil }
        guard !isStopping else { return nil }
        isStopping = true
        defer { isStopping = false }

        let fileURL = await recorder.stopRecording()
        
        // Let the backend know where the file is so it can process it
        do {
            if let path = fileURL?.path {
                let updatedMeeting = try await APIClient.shared.updateMeeting(id: meeting.id, audioFilePath: path)
                try await APIClient.shared.triggerProcessing(meetingId: meeting.id)
                currentMeeting = nil
                meetingTitle = ""
                return updatedMeeting
            } else {
                // If we couldn't get a file path for some reason, just return the meeting
                currentMeeting = nil
                meetingTitle = ""
                return meeting
            }
        } catch {
            errorMessage = error.localizedDescription
            return meeting // Return the old one so HomeView can still show it, even if processing failed to start
        }
    }

    private func meetingDir(for meetingId: String) -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AI-Meetings/meetings/\(meetingId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func audioOutputURL(for meetingId: String) -> URL {
        meetingDir(for: meetingId).appendingPathComponent("audio.m4a")
    }

    private func videoOutputURL(for meetingId: String) -> URL {
        meetingDir(for: meetingId).appendingPathComponent("recording.mp4")
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
    @Published var isSummarizing = false
    @Published var errorMessage: String?

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
            
            if meeting?.status.isProcessing == true {
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
                    
                    if !updated.status.isProcessing {
                        // Finished processing! Fetch the newly generated resources
                        self.transcript = (try? await APIClient.shared.fetchTranscript(meetingId: meetingId)) ?? []
                        self.speakers   = (try? await APIClient.shared.fetchSpeakers(meetingId: meetingId)) ?? []
                        self.summary    = try? await APIClient.shared.fetchSummary(meetingId: meetingId)
                        self.tasks      = (try? await APIClient.shared.fetchTasks(meetingId: meetingId)) ?? []
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

    func retryProcessing() async {
        guard let m = meeting else { return }
        do {
            try await APIClient.shared.triggerProcessing(meetingId: m.id)
            await loadAll(meetingId: m.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generateSummary(provider: String = "ollama", model: String = "llama3") async {
        guard let meeting else { return }
        isSummarizing = true
        do {
            try await APIClient.shared.generateSummary(meetingId: meeting.id, provider: provider, model: model)
            // Poll briefly for completion
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                summary = try? await APIClient.shared.fetchSummary(meetingId: meeting.id)
                if summary != nil { break }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSummarizing = false
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
}

// MARK: - SettingsViewModel

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings = .default
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { settings = try await APIClient.shared.fetchSettings() }
        catch { errorMessage = error.localizedDescription }
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
}

// MARK: - PermissionsViewModel

import AVFoundation
import CoreGraphics
import AppKit

@MainActor
final class PermissionsViewModel: ObservableObject {
    @Published var hasMicAccess = false
    @Published var hasScreenAccess = false
    
    init() {
        checkPermissions()
    }
    
    func checkPermissions() {
        // Check Microphone
        hasMicAccess = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        
        // Check Screen Recording (macOS 14+ uses SCShareableContent, but CGPreflight is available since 11.0)
        hasScreenAccess = CGPreflightScreenCaptureAccess()
    }
    
    func requestMicAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.hasMicAccess = granted
            }
        }
    }
    
    func requestScreenAccess() {
        // This will pop the system prompt if not yet granted
        let granted = CGRequestScreenCaptureAccess()
        hasScreenAccess = granted
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
