import Foundation

// MARK: - Calendar

enum CalendarSource: String, Codable, CaseIterable {
    case google
    case microsoft
}

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarSource: CalendarSource
    let onlineMeetingUrl: String?
}

// MARK: - Meeting

/// Mirrored from backend MeetingOut schema.
struct Meeting: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var startedAt: Date?
    var endedAt: Date?
    var durationSeconds: Double?
    var status: MeetingStatus
    var audioFilePath: String?
    var normalizedAudioPath: String?
    var transcriptJsonPath: String?
    var summaryJsonPath: String?
    var createdAt: Date
    var updatedAt: Date?
    var speakersPreview: [String]
    var calendarEventId: String?
    var calendarSource: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case audioFilePath = "audio_file_path"
        case normalizedAudioPath = "normalized_audio_path"
        case transcriptJsonPath = "transcript_json_path"
        case summaryJsonPath = "summary_json_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case speakersPreview = "speakers_preview"
        case calendarEventId = "calendar_event_id"
        case calendarSource = "calendar_source"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(MeetingStatus.self, forKey: .status)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        audioFilePath = try c.decodeIfPresent(String.self, forKey: .audioFilePath)
        normalizedAudioPath = try c.decodeIfPresent(String.self, forKey: .normalizedAudioPath)
        transcriptJsonPath = try c.decodeIfPresent(String.self, forKey: .transcriptJsonPath)
        summaryJsonPath = try c.decodeIfPresent(String.self, forKey: .summaryJsonPath)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        speakersPreview = (try? c.decodeIfPresent([String].self, forKey: .speakersPreview)) ?? []
        calendarEventId = try c.decodeIfPresent(String.self, forKey: .calendarEventId)
        calendarSource = try c.decodeIfPresent(String.self, forKey: .calendarSource)
    }
}

enum MeetingStatus: String, Codable, CaseIterable {
    case created
    case recording
    case preprocessing
    case transcribing
    case matchingSpeakers = "matching_speakers"
    case transcriptReady = "transcript_ready"
    case summarizing
    case complete
    case failed

    var displayName: String {
        switch self {
        case .created:          return "Created"
        case .recording:        return "Recording"
        case .preprocessing:    return "Preprocessing Audio"
        case .transcribing:     return "Transcribing"
        case .matchingSpeakers: return "Matching Speakers"
        case .transcriptReady:  return "Transcript Ready"
        case .summarizing:      return "Generating Summary"
        case .complete:         return "Complete"
        case .failed:           return "Failed"
        }
    }

    var isProcessing: Bool {
        switch self {
        case .preprocessing, .transcribing, .matchingSpeakers, .summarizing:
            return true
        default:
            return false
        }
    }

    /// True when the meeting is in any transient state that the UI should poll for updates.
    /// Includes `.recording` to handle the brief window between recording stop and
    /// pipeline start where the backend hasn't yet transitioned to `.preprocessing`.
    var needsPolling: Bool {
        switch self {
        case .recording, .preprocessing, .transcribing, .matchingSpeakers, .summarizing:
            return true
        default:
            return false
        }
    }
}

// MARK: - Transcript

/// A single spoken segment in a transcript.
struct TranscriptSegment: Identifiable, Codable {
    let id: String
    let meetingId: String
    let clusterId: String?
    var speakerLabel: String?
    let startMs: Int
    let endMs: Int
    let text: String
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case id, text, confidence
        case meetingId = "meeting_id"
        case clusterId = "cluster_id"
        case speakerLabel = "speaker_label"
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    /// Formatted timestamp string e.g. "01:23:45"
    var timestampString: String {
        let totalSeconds = startMs / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Speaker Cluster

struct SpeakerCluster: Identifiable, Codable {
    let id: String
    let meetingId: String
    var tempLabel: String
    var assignedPersonId: String?
    var suggestedPersonId: String?
    var suggestedPersonName: String?
    var confidence: Double?
    var durationSeconds: Double?
    var segmentCount: Int
    var duplicateGroupHint: String?

    enum CodingKeys: String, CodingKey {
        case id, confidence
        case meetingId = "meeting_id"
        case tempLabel = "temp_label"
        case assignedPersonId = "assigned_person_id"
        case suggestedPersonId = "suggested_person_id"
        case suggestedPersonName = "suggested_person_name"
        case durationSeconds = "duration_seconds"
        case segmentCount = "segment_count"
        case duplicateGroupHint = "duplicate_group_hint"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        meetingId = try c.decode(String.self, forKey: .meetingId)
        tempLabel = try c.decode(String.self, forKey: .tempLabel)
        assignedPersonId = try c.decodeIfPresent(String.self, forKey: .assignedPersonId)
        suggestedPersonId = try c.decodeIfPresent(String.self, forKey: .suggestedPersonId)
        suggestedPersonName = try c.decodeIfPresent(String.self, forKey: .suggestedPersonName)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        segmentCount = try c.decode(Int.self, forKey: .segmentCount)
        duplicateGroupHint = try c.decodeIfPresent(String.self, forKey: .duplicateGroupHint)
    }
}

// MARK: - Person

struct Person: Identifiable, Codable {
    let id: String
    var displayName: String
    var notes: String?
    var lastSeenAt: Date?
    var meetingCount: Int
    var createdAt: Date
    var updatedAt: Date
    var hasVoiceEmbedding: Bool

    enum CodingKeys: String, CodingKey {
        case id, notes
        case displayName = "display_name"
        case lastSeenAt = "last_seen_at"
        case meetingCount = "meeting_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case hasVoiceEmbedding = "has_voice_embedding"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        meetingCount = try c.decode(Int.self, forKey: .meetingCount)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        hasVoiceEmbedding = (try? c.decodeIfPresent(Bool.self, forKey: .hasVoiceEmbedding)) ?? false
    }
}

// MARK: - Summary

struct MeetingSummary: Codable {
    let id: String
    let meetingId: String
    let provider: String
    let model: String
    let summaryMarkdown: String?
    let summaryJson: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, provider, model
        case meetingId = "meeting_id"
        case summaryMarkdown = "summary_markdown"
        case summaryJson = "summary_json"
        case createdAt = "created_at"
    }
}

// MARK: - Task

struct MeetingTask: Identifiable, Codable {
    let id: String
    let meetingId: String
    var ownerPersonId: String?
    var rawOwnerText: String?
    var description: String
    var dueDate: String?
    var status: String

    enum CodingKeys: String, CodingKey {
        case id, description, status
        case meetingId = "meeting_id"
        case ownerPersonId = "owner_person_id"
        case rawOwnerText = "raw_owner_text"
        case dueDate = "due_date"
    }
}

// MARK: - Dependency Health

struct DependencyCheck: Identifiable, Codable {
    let key: String
    let name: String
    let status: String   // "ok" | "missing" | "not_configured"
    let detail: String
    let required: Bool

    var id: String { key }
    var isOk: Bool { status == "ok" }
}

struct DependenciesResult: Codable {
    let allRequiredOk: Bool
    let checks: [DependencyCheck]

    enum CodingKeys: String, CodingKey {
        case allRequiredOk = "all_required_ok"
        case checks
    }
}

// MARK: - App Settings

struct AppSettings: Codable {
    var elevenLabsApiKey: String
    var openAiApiKey: String
    var anthropicApiKey: String
    var geminiApiKey: String
    var ollamaEndpoint: String
    var defaultLlmProvider: String
    var defaultLlmModel: String
    var defaultTranscriptionProvider: String
    var baseStorageDir: String
    var speakerSuggestThreshold: Double
    var speakerAutoAssignThreshold: Double
    var speakerDuplicateThreshold: Double
    var googleCalendarConnected: Bool? = nil
    var outlookConnected: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case ollamaEndpoint = "ollama_endpoint"
        case baseStorageDir = "base_storage_dir"
        case elevenLabsApiKey = "elevenlabs_api_key"
        case openAiApiKey = "openai_api_key"
        case anthropicApiKey = "anthropic_api_key"
        case geminiApiKey = "gemini_api_key"
        case defaultLlmProvider = "default_llm_provider"
        case defaultLlmModel = "default_llm_model"
        case defaultTranscriptionProvider = "default_transcription_provider"
        case speakerSuggestThreshold = "speaker_suggest_threshold"
        case speakerAutoAssignThreshold = "speaker_auto_assign_threshold"
        case speakerDuplicateThreshold = "speaker_duplicate_threshold"
        case googleCalendarConnected = "google_calendar_connected"
        case outlookConnected = "outlook_connected"
    }

    static var `default`: AppSettings {
        AppSettings(
            elevenLabsApiKey: "",
            openAiApiKey: "",
            anthropicApiKey: "",
            geminiApiKey: "",
            ollamaEndpoint: "http://localhost:11434",
            defaultLlmProvider: "ollama",
            defaultLlmModel: "llama3",
            defaultTranscriptionProvider: "elevenlabs",
            baseStorageDir: "~/Documents/AI-Meetings",
            speakerSuggestThreshold: 0.75,
            speakerAutoAssignThreshold: 0.90,
            speakerDuplicateThreshold: 0.82
        )
    }
}
