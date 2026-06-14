import Foundation
import Combine

// MARK: - Chat Models

struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Equatable { case user, assistant }

    let id: UUID
    let role: Role
    var content: String          // mutable so streaming can append tokens
    var isStreaming: Bool         // true while tokens are still arriving
    let timestamp: Date

    init(role: Role, content: String = "", isStreaming: Bool = false) {
        self.id          = UUID()
        self.role        = role
        self.content     = content
        self.isStreaming = isStreaming
        self.timestamp   = Date()
    }
}

// MARK: - ViewModel

@MainActor
final class ChatViewModel: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var selectedProvider: String = "openai"
    @Published var selectedModel: String = ""

    private let baseURL: String

    // Providers and their sensible default models
    let providers: [(id: String, label: String, defaultModel: String)] = [
        ("openai",    "OpenAI",    "gpt-4o-mini"),
        ("anthropic", "Anthropic", "claude-3-5-haiku-latest"),
        ("gemini",    "Gemini",    "gemini-1.5-flash"),
        ("ollama",    "Ollama",    "llama3.1"),
    ]

    // UserDefaults keys for persisting provider/model selection
    private static let providerKey = "klarityChatProvider"
    private static let modelKey = "klarityChatModel"

    init(baseURL: String = "http://127.0.0.1:8765") {
        self.baseURL = baseURL
        // Restore saved provider/model, or fall back to defaults
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
        let savedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        if let p = savedProvider, providers.contains(where: { $0.id == p }) {
            selectedProvider = p
        }
        if let m = savedModel, !m.isEmpty {
            selectedModel = m
        } else {
            selectedModel = providers.first(where: { $0.id == selectedProvider })?.defaultModel ?? ""
        }
    }

    // Called when the user taps Send
    func sendMessage() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading else { return }

        // Append user bubble
        let userMsg = ChatMessage(role: .user, content: trimmed)
        messages.append(userMsg)
        inputText = ""
        errorMessage = nil
        isLoading = true

        // Create a placeholder assistant bubble that will stream tokens into
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)
        let assistantIdx = messages.count - 1

        // Build conversation history for the API (omit isStreaming metadata)
        let history = messages.dropLast().map { m in
            ["role": m.role.rawValue, "content": m.content]
        }

        do {
            try await streamChat(
                history: Array(history),
                onToken: { [weak self] token in
                    guard let self else { return }
                    self.messages[assistantIdx].content += token
                },
                onDone: { [weak self] in
                    guard let self else { return }
                    self.messages[assistantIdx].isStreaming = false
                    self.isLoading = false
                },
                onError: { [weak self] err in
                    guard let self else { return }
                    self.messages[assistantIdx].content = "⚠️ \(err)"
                    self.messages[assistantIdx].isStreaming = false
                    self.isLoading = false
                    self.errorMessage = err
                }
            )
        } catch {
            messages[assistantIdx].content = "⚠️ \(error.localizedDescription)"
            messages[assistantIdx].isStreaming = false
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func clearConversation() {
        messages = []
        errorMessage = nil
    }

    // Update default model when user switches provider
    func onProviderChanged() {
        selectedModel = providers.first(where: { $0.id == selectedProvider })?.defaultModel ?? ""
        UserDefaults.standard.set(selectedProvider, forKey: Self.providerKey)
        UserDefaults.standard.set(selectedModel, forKey: Self.modelKey)
    }

    func saveModelSelection() {
        UserDefaults.standard.set(selectedModel, forKey: Self.modelKey)
    }

    // MARK: - Streaming Request

    private func streamChat(
        history: [[String: String]],
        onToken: @escaping (String) -> Void,
        onDone: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) async throws {

        guard let url = URL(string: "\(baseURL)/chat") else {
            onError("Invalid backend URL")
            return
        }

        let body: [String: Any] = [
            "provider": selectedProvider,
            "model":    selectedModel,
            "messages": history,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            onError("Backend returned HTTP \(http.statusCode)")
            return
        }

        // Parse SSE frames line by line
        var eventType = ""
        for try await line in asyncBytes.lines {
            if line.hasPrefix("event:") {
                eventType = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let raw = String(line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces))
                // Strip outer JSON quotes — the server wraps the string in JSON
                let decoded = (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
                switch eventType {
                case "token": onToken(decoded)
                case "done":  onDone(); return
                case "error": onError(decoded); return
                default:      break
                }
                eventType = ""
            }
        }
        onDone()
    }
}
