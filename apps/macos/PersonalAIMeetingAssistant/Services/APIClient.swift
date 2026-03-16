import Foundation
import os.log

/// Singleton HTTP client for communicating with the local FastAPI backend.
final class APIClient {
    static let shared = APIClient()

    private let baseURL: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger = Logger(subsystem: "com.klarity.meeting-assistant", category: "APIClient")

    private init(baseURL: String = "http://127.0.0.1:8765") {
        self.baseURL = baseURL
        self.session = URLSession.shared

        decoder = JSONDecoder()
        // Python's datetime outputs ISO8601 strings in up to 4 formats — we must handle all:
        //   "2026-03-10T07:21:02"               (no TZ, no fractional)
        //   "2026-03-10T07:21:02.254380"        (no TZ, with microseconds)  ← most common
        //   "2026-03-10T07:21:02+00:00"         (with TZ, no fractional)
        //   "2026-03-10T07:21:02.254380+00:00"  (with TZ, with microseconds)
        decoder.dateDecodingStrategy = .custom { dec in
            let raw = try dec.singleValueContainer().decode(String.self)
            // Append Z if there's no timezone offset so ISO8601DateFormatter can parse it
            let str = (raw.hasSuffix("Z") || raw.contains("+") || (raw.count > 19 && raw.last?.isNumber == false))
                ? raw
                : raw + "Z"
            // Try fractional seconds first (Python's utcnow() default)
            let fmtFrac = ISO8601DateFormatter()
            fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fmtFrac.date(from: str) { return date }
            // Plain seconds
            let fmtPlain = ISO8601DateFormatter()
            fmtPlain.formatOptions = [.withInternetDateTime]
            if let date = fmtPlain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: try dec.singleValueContainer(),
                debugDescription: "Cannot parse date from backend: \(raw)"
            )
        }

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Health

    func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Dependencies

    func fetchDependencies() async throws -> DependenciesResult {
        try await get("/health/dependencies")
    }

    func fetchOllamaModels() async throws -> [String] {
        struct OllamaModelsResponse: Decodable { let models: [String] }
        let resp: OllamaModelsResponse = try await get("/health/ollama/models")
        return resp.models
    }

    // MARK: - Meetings

    func fetchMeetings() async throws -> [Meeting] {
        try await get("/meetings")
    }

    func fetchMeeting(id: String) async throws -> Meeting {
        try await get("/meetings/\(id)")
    }

    func createMeeting(title: String, calendarEventId: String? = nil, calendarSource: String? = nil) async throws -> Meeting {
        struct Body: Encodable {
            let title: String
            let calendarEventId: String?
            let calendarSource: String?
            enum CodingKeys: String, CodingKey {
                case title
                case calendarEventId = "calendar_event_id"
                case calendarSource  = "calendar_source"
            }
        }
        return try await post("/meetings", body: Body(title: title, calendarEventId: calendarEventId, calendarSource: calendarSource))
    }

    func updateMeeting(id: String, audioFilePath: String, durationSeconds: Double? = nil) async throws -> Meeting {
        var body: [String: Any] = ["audio_file_path": audioFilePath]
        if let dur = durationSeconds {
            body["duration_seconds"] = dur
            let iso = ISO8601DateFormatter()
            body["ended_at"] = iso.string(from: Date())
        }
        logger.debug("Sending PATCH /meetings/\(id)")

        var req = URLRequest(url: try url(for: "/meetings/\(id)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← PATCH /meetings/\(id) resulted in \(status) body: \(String(data: data, encoding: .utf8) ?? "")")

        try validate(response: resp, data: data)
        return try decoder.decode(Meeting.self, from: data)
    }

    func renameMeeting(id: String, title: String) async throws -> Meeting {
        try await patch("/meetings/\(id)", body: ["title": title])
    }

    func deleteMeeting(id: String) async throws {
        try await delete("/meetings/\(id)")
    }

    func triggerProcessing(meetingId: String) async throws {
        var req = URLRequest(url: try url(for: "/meetings/\(meetingId)/process"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        logger.debug("Sending POST /meetings/\(meetingId)/process")
        
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← POST /meetings/\(meetingId)/process resulted in \(status) body: \(String(data: data, encoding: .utf8) ?? "")")
        
        try validate(response: resp, data: data)
    }

    func reprocessSummary(meetingId: String) async throws {
        let _: EmptyResponse = try await post("/meetings/\(meetingId)/reprocess-summary", body: EmptyBody())
    }

    // MARK: - Transcript

    func fetchTranscript(meetingId: String) async throws -> [TranscriptSegment] {
        try await get("/meetings/\(meetingId)/transcript")
    }

    func fetchSpeakers(meetingId: String) async throws -> [SpeakerCluster] {
        try await get("/meetings/\(meetingId)/speakers")
    }

    func assignSpeaker(meetingId: String, clusterId: String, personId: String? = nil, newPersonName: String? = nil) async throws {
        var body: [String: String?] = ["cluster_id": clusterId]
        body["person_id"] = personId
        body["new_person_name"] = newPersonName
        let _: EmptyResponse = try await post("/meetings/\(meetingId)/assign-speaker", body: body)
    }

    func mergeSpeakers(meetingId: String, sourceIds: [String], targetId: String, personId: String? = nil, newName: String? = nil) async throws {
        var body: [String: Any] = [
            "source_cluster_ids": sourceIds,
            "target_cluster_id": targetId
        ]
        if let p = personId { body["target_person_id"] = p }
        if let n = newName { body["new_person_name"] = n }
        let data = try JSONSerialization.data(withJSONObject: body)
        try await postData("/meetings/\(meetingId)/merge-speakers", body: data)
    }

    // MARK: - Summary

    func fetchSummary(meetingId: String) async throws -> MeetingSummary? {
        try await getOptional("/meetings/\(meetingId)/summary")
    }

    func generateSummary(meetingId: String, provider: String, model: String) async throws {
        let body = ["provider": provider, "model": model]
        let _: EmptyResponse = try await post("/meetings/\(meetingId)/generate-summary", body: body)
    }

    func fetchTasks(meetingId: String) async throws -> [MeetingTask] {
        try await get("/meetings/\(meetingId)/tasks")
    }

    // MARK: - People

    func fetchPeople() async throws -> [Person] {
        try await get("/people")
    }

    func fetchPersonMeetings(personId: String) async throws -> [Meeting] {
        try await get("/people/\(personId)/meetings")
    }

    func recomputePersonEmbedding(personId: String) async throws {
        let _: EmptyResponse = try await post("/people/\(personId)/recompute-embedding", body: EmptyBody())
    }

    func createPerson(displayName: String, notes: String? = nil) async throws -> Person {
        var body: [String: String?] = ["display_name": displayName]
        body["notes"] = notes
        return try await post("/people", body: body)
    }

    func updatePerson(id: String, displayName: String?, notes: String?) async throws -> Person {
        var body: [String: String?] = [:]
        body["display_name"] = displayName
        body["notes"] = notes
        return try await patch("/people/\(id)", body: body)
    }

    func deletePerson(id: String) async throws {
        try await delete("/people/\(id)")
    }

    // MARK: - Settings

    func fetchSettings() async throws -> AppSettings {
        try await get("/settings")
    }

    func updateSettings(_ patch: [String: Any]) async throws -> AppSettings {
        let data = try JSONSerialization.data(withJSONObject: patch)
        return try await patchData("/settings", body: data)
    }

    // MARK: - Generic HTTP helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = "GET"
        logger.debug("→ GET \(path)")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← GET \(path) \(status)")
        try validate(response: resp, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func getOptional<T: Decodable>(_ path: String) async throws -> T? {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = "GET"
        logger.debug("→ GET \(path) (optional)")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← GET \(path) \(status)")
        if let http = resp as? HTTPURLResponse, http.statusCode == 204 { return nil }
        try validate(response: resp, data: data)
        if data == "null".data(using: .utf8) { return nil }
        return try decoder.decode(T.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        if let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) {
            logger.debug("→ POST \(path) body: \(bodyStr)")
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← POST \(path) \(status)")
        try validate(response: resp, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func postData<Response: Decodable>(_ path: String, body: Data) async throws -> Response {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        logger.debug("→ POST \(path) (raw data \(body.count)b)")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← POST \(path) \(status)")
        try validate(response: resp, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func postData(_ path: String, body: Data) async throws {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        logger.debug("→ POST \(path) (no response expected)")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← POST \(path) \(status)")
        try validate(response: resp, data: data)
    }

    private func patch<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        logger.debug("→ PATCH \(path)")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← PATCH \(path) \(status)")
        try validate(response: resp, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func patchData<Response: Decodable>(_ path: String, body: Data) async throws -> Response {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        logger.debug("→ PATCH \(path) (raw data \(body.count)b)")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← PATCH \(path) \(status)")
        try validate(response: resp, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func delete(_ path: String) async throws {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = "DELETE"
        logger.debug("→ DELETE \(path)")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        logger.debug("← DELETE \(path) \(status)")
        if let http = resp as? HTTPURLResponse, http.statusCode == 204 { return }
        try validate(response: resp, data: data)
    }

    /// Validates HTTP status code and throws a descriptive error for non-2xx responses.
    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let rawBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            // Try to extract FastAPI's { "detail": "..." } message
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["detail"] as? String }
            let message = detail ?? "HTTP \(http.statusCode)"
            logger.error("API error \(http.statusCode): \(message) | raw: \(rawBody)")
            throw APIError.serverError(statusCode: http.statusCode, detail: message)
        }
    }

    private func url(for path: String) throws -> URL {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }
        return url
    }
}

// MARK: - Error type

enum APIError: LocalizedError {
    case serverError(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .serverError(let code, let detail):
            return "Server error \(code): \(detail)"
        }
    }
}

// MARK: - Helpers

private struct EmptyBody: Encodable {}
private struct EmptyResponse: Decodable {}
