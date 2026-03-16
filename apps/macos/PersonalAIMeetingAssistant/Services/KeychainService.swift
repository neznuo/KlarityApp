import Foundation
import Security

/// Secure storage for API keys using macOS Keychain.
/// Keys are stored per-account under the Klarity service namespace.
enum KeychainService {
    private static let service = "com.klarity.meeting-assistant"

    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Well-known key constants

extension KeychainService {
    static let elevenLabsKey = "elevenlabs_api_key"
    static let openAIKey     = "openai_api_key"
    static let anthropicKey  = "anthropic_api_key"
    static let geminiKey     = "gemini_api_key"

    // Google Calendar OAuth tokens
    static let googleAccessToken  = "calendar.google.access_token"
    static let googleRefreshToken = "calendar.google.refresh_token"
    static let googleTokenExpiry  = "calendar.google.token_expiry"

    // Microsoft (Outlook) OAuth tokens
    static let msAccessToken  = "calendar.microsoft.access_token"
    static let msRefreshToken = "calendar.microsoft.refresh_token"
    static let msTokenExpiry  = "calendar.microsoft.token_expiry"
}
