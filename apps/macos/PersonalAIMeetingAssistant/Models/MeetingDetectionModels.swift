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