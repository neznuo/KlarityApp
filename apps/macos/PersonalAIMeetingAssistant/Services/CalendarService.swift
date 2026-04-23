import Foundation
import AuthenticationServices
import CryptoKit
import os.log

/// Manages OAuth authentication and calendar event fetching for Google Calendar and Outlook.
/// All OAuth tokens are stored in the macOS Keychain; no tokens are sent to the backend.
@MainActor
final class CalendarService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = CalendarService()

    private let urlSession = URLSession.shared
    private let logger = AppLogger(category: "CalendarService")

    /// Retains the active auth session to prevent premature deallocation.
    private var authSession: ASWebAuthenticationSession?

    private var googleClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "KlarityGoogleClientID") as? String ?? ""
    }

    /// Google requires the reverse client ID as the URL scheme for native app OAuth.
    /// Format: com.googleusercontent.apps.CLIENT_ID (the ".apps.googleusercontent.com" suffix is removed).
    private var googleReverseClientID: String {
        let clientID = googleClientID
        // e.g. "XXXXXXXX-YYYY.apps.googleusercontent.com"
        // → "com.googleusercontent.apps.XXXXXXXX-YYYY"
        let parts = clientID.components(separatedBy: ".")
        if parts.count >= 4 && clientID.hasSuffix(".apps.googleusercontent.com") {
            return "com.googleusercontent.apps." + parts.dropLast(3).joined(separator: ".")
        }
        // Fallback: reverse the whole thing
        return clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private var googleRedirectURI: String {
        "\(googleReverseClientID):/oauth2callback"
    }

    private var microsoftClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "KlarityMicrosoftClientID") as? String ?? ""
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return verifier }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Public API

    func isConnected(_ provider: CalendarSource) -> Bool {
        switch provider {
        case .google:    return (try? KeychainService.load(key: KeychainService.googleAccessToken)) != nil
        case .microsoft: return (try? KeychainService.load(key: KeychainService.msAccessToken)) != nil
        }
    }

    func authenticate(provider: CalendarSource) async throws {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let authURL = buildAuthURL(provider: provider, challenge: challenge)

        let callbackScheme = provider == .google ? googleReverseClientID : "klarity"
        let callbackURL: URL = try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else { cont.resume(throwing: CalendarError.deallocated); return }
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, error in
                if let error { cont.resume(throwing: error); return }
                guard let url else { cont.resume(throwing: CalendarError.noCallbackURL); return }
                cont.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.authSession = session
            session.start()
        }
        authSession = nil

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw CalendarError.noAuthCode }

        try await exchangeCode(code, verifier: verifier, provider: provider)
        logger.info("Authenticated with \(provider.rawValue)")
    }

    func disconnect(_ provider: CalendarSource) {
        switch provider {
        case .google:
            try? KeychainService.delete(key: KeychainService.googleAccessToken)
            try? KeychainService.delete(key: KeychainService.googleRefreshToken)
            try? KeychainService.delete(key: KeychainService.googleTokenExpiry)
            Task { _ = try? await APIClient.shared.updateSettings(["google_calendar_connected": false]) }
        case .microsoft:
            try? KeychainService.delete(key: KeychainService.msAccessToken)
            try? KeychainService.delete(key: KeychainService.msRefreshToken)
            try? KeychainService.delete(key: KeychainService.msTokenExpiry)
            Task { _ = try? await APIClient.shared.updateSettings(["outlook_connected": false]) }
        }
        logger.info("Disconnected \(provider.rawValue)")
    }

    func fetchAllEvents() async -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        for provider in CalendarSource.allCases where isConnected(provider) {
            if let providerEvents = try? await fetchEvents(for: provider) {
                events.append(contentsOf: providerEvents)
            }
        }
        return events.sorted { $0.startDate < $1.startDate }
    }

    /// Throwing variant — surfaces errors when all providers fail. Returns partial results if at least one succeeds.
    func fetchAllEventsThrowing() async throws -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var lastError: Error?
        for provider in CalendarSource.allCases where isConnected(provider) {
            do {
                let providerEvents = try await fetchEvents(for: provider)
                events.append(contentsOf: providerEvents)
            } catch {
                lastError = error
            }
        }
        if events.isEmpty, let lastError {
            throw lastError
        }
        return events.sorted { $0.startDate < $1.startDate }
    }

    func fetchEvents(for provider: CalendarSource) async throws -> [CalendarEvent] {
        try await refreshTokenIfNeeded(for: provider)
        return try await doFetchEvents(for: provider)
    }

    // MARK: - Token Refresh

    func refreshTokenIfNeeded(for provider: CalendarSource) async throws {
        let expiryKey: String
        let refreshKey: String
        let accessKey: String
        let tokenURL: URL
        var params: [String: String]

        switch provider {
        case .google:
            expiryKey = KeychainService.googleTokenExpiry
            refreshKey = KeychainService.googleRefreshToken
            accessKey = KeychainService.googleAccessToken
            tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
            params = ["grant_type": "refresh_token", "client_id": googleClientID]
        case .microsoft:
            expiryKey = KeychainService.msTokenExpiry
            refreshKey = KeychainService.msRefreshToken
            accessKey = KeychainService.msAccessToken
            tokenURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
            params = ["grant_type": "refresh_token", "client_id": microsoftClientID,
                      "scope": "Calendars.Read offline_access"]
        }

        // Check if token is still valid (with 60s buffer)
        if let expiryStr = try KeychainService.load(key: expiryKey),
           let expiryTs = Double(expiryStr),
           Date().timeIntervalSince1970 < expiryTs - 60 {
            return
        }

        guard let refreshToken = try KeychainService.load(key: refreshKey) else {
            throw CalendarError.noRefreshToken
        }
        params["refresh_token"] = refreshToken

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await urlSession.data(for: req)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        try KeychainService.save(key: accessKey, value: response.accessToken)
        if let newRefresh = response.refreshToken {
            try KeychainService.save(key: refreshKey, value: newRefresh)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600))
        try KeychainService.save(key: expiryKey, value: "\(expiry.timeIntervalSince1970)")
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }

    // MARK: - Private Helpers

    private func buildAuthURL(provider: CalendarSource, challenge: String) -> URL {
        switch provider {
        case .google:
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: googleClientID),
                URLQueryItem(name: "redirect_uri", value: googleRedirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar.readonly"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
            return components.url!
        case .microsoft:
            var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: microsoftClientID),
                URLQueryItem(name: "redirect_uri", value: "klarity://oauth/microsoft/callback"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "Calendars.Read offline_access"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            return components.url!
        }
    }

    private func exchangeCode(_ code: String, verifier: String, provider: CalendarSource) async throws {
        let tokenURL: URL
        var params: [String: String]

        switch provider {
        case .google:
            tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
            params = [
                "code": code,
                "client_id": googleClientID,
                "redirect_uri": googleRedirectURI,
                "grant_type": "authorization_code",
                "code_verifier": verifier,
            ]
        case .microsoft:
            tokenURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
            params = [
                "code": code,
                "client_id": microsoftClientID,
                "redirect_uri": "klarity://oauth/microsoft/callback",
                "grant_type": "authorization_code",
                "code_verifier": verifier,
                "scope": "Calendars.Read offline_access",
            ]
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

        let (data, _) = try await urlSession.data(for: req)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        switch provider {
        case .google:
            try KeychainService.save(key: KeychainService.googleAccessToken, value: response.accessToken)
            if let refresh = response.refreshToken {
                try KeychainService.save(key: KeychainService.googleRefreshToken, value: refresh)
            }
            let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600))
            try KeychainService.save(key: KeychainService.googleTokenExpiry, value: "\(expiry.timeIntervalSince1970)")
            _ = try? await APIClient.shared.updateSettings(["google_calendar_connected": true])
        case .microsoft:
            try KeychainService.save(key: KeychainService.msAccessToken, value: response.accessToken)
            if let refresh = response.refreshToken {
                try KeychainService.save(key: KeychainService.msRefreshToken, value: refresh)
            }
            let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600))
            try KeychainService.save(key: KeychainService.msTokenExpiry, value: "\(expiry.timeIntervalSince1970)")
            _ = try? await APIClient.shared.updateSettings(["outlook_connected": true])
        }
    }

    private func doFetchEvents(for provider: CalendarSource) async throws -> [CalendarEvent] {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .hour, value: 24, to: now)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        switch provider {
        case .google:
            guard let accessToken = try KeychainService.load(key: KeychainService.googleAccessToken) else {
                throw CalendarError.notAuthenticated
            }
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
            components.queryItems = [
                URLQueryItem(name: "timeMin", value: fmt.string(from: now)),
                URLQueryItem(name: "timeMax", value: fmt.string(from: tomorrow)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "20"),
            ]
            var req = URLRequest(url: components.url!)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await urlSession.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 401 {
                try await refreshTokenIfNeeded(for: .google)
                let fresh = try KeychainService.load(key: KeychainService.googleAccessToken) ?? ""
                req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                let (data2, _) = try await urlSession.data(for: req)
                return try parseGoogleEvents(data2)
            }
            return try parseGoogleEvents(data)

        case .microsoft:
            guard let accessToken = try KeychainService.load(key: KeychainService.msAccessToken) else {
                throw CalendarError.notAuthenticated
            }
            var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarView")!
            components.queryItems = [
                URLQueryItem(name: "startDateTime", value: fmt.string(from: now)),
                URLQueryItem(name: "endDateTime", value: fmt.string(from: tomorrow)),
                URLQueryItem(name: "$top", value: "20"),
                URLQueryItem(name: "$orderby", value: "start/dateTime"),
            ]
            var req = URLRequest(url: components.url!)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await urlSession.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 401 {
                try await refreshTokenIfNeeded(for: .microsoft)
                let fresh = try KeychainService.load(key: KeychainService.msAccessToken) ?? ""
                req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                let (data2, _) = try await urlSession.data(for: req)
                return try parseMicrosoftEvents(data2)
            }
            return try parseMicrosoftEvents(data)
        }
    }

    private func parseGoogleEvents(_ data: Data) throws -> [CalendarEvent] {
        struct Response: Decodable { let items: [Item]? }
        struct Item: Decodable {
            let id: String
            let summary: String?
            let start: EventTime
            let end: EventTime
            let conferenceData: ConferenceData?
            struct EventTime: Decodable { let dateTime: String?; let date: String? }
            struct ConferenceData: Decodable {
                let entryPoints: [EntryPoint]?
                struct EntryPoint: Decodable { let entryPointType: String; let uri: String }
            }
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        let fmtFrac = ISO8601DateFormatter(); fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtPlain = ISO8601DateFormatter(); fmtPlain.formatOptions = [.withInternetDateTime]

        func parse(_ str: String) -> Date? { fmtFrac.date(from: str) ?? fmtPlain.date(from: str) }

        return (response.items ?? []).compactMap { item in
            guard let startStr = item.start.dateTime ?? item.start.date,
                  let endStr   = item.end.dateTime   ?? item.end.date,
                  let start    = parse(startStr),
                  let end      = parse(endStr) else { return nil }
            let meetingURL = item.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
            return CalendarEvent(id: item.id, title: item.summary ?? "Untitled",
                                 startDate: start, endDate: end,
                                 calendarSource: .google, onlineMeetingUrl: meetingURL)
        }
    }

    private func parseMicrosoftEvents(_ data: Data) throws -> [CalendarEvent] {
        struct Response: Decodable { let value: [Item]? }
        struct Item: Decodable {
            let id: String
            let subject: String?
            let start: EventTime
            let end: EventTime
            let onlineMeetingUrl: String?
            struct EventTime: Decodable { let dateTime: String; let timeZone: String }
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        let fmtFrac = ISO8601DateFormatter(); fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtPlain = ISO8601DateFormatter(); fmtPlain.formatOptions = [.withInternetDateTime]

        func parse(_ str: String) -> Date? {
            let s = str.hasSuffix("Z") ? str : str + "Z"
            return fmtFrac.date(from: s) ?? fmtPlain.date(from: s)
        }

        return (response.value ?? []).compactMap { item in
            guard let start = parse(item.start.dateTime),
                  let end   = parse(item.end.dateTime) else { return nil }
            return CalendarEvent(id: item.id, title: item.subject ?? "Untitled",
                                 startDate: start, endDate: end,
                                 calendarSource: .microsoft, onlineMeetingUrl: item.onlineMeetingUrl)
        }
    }

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}

// MARK: - Supporting Types

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
    }
}

enum CalendarError: LocalizedError {
    case deallocated
    case noCallbackURL
    case noAuthCode
    case noRefreshToken
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .deallocated:       return "CalendarService was deallocated."
        case .noCallbackURL:     return "No callback URL received from OAuth."
        case .noAuthCode:        return "No authorization code in OAuth callback."
        case .noRefreshToken:    return "No refresh token stored. Please reconnect."
        case .notAuthenticated:  return "No access token. Please connect your calendar."
        }
    }
}
