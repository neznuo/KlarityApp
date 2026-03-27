import SwiftUI

struct SettingsView: View {
    @StateObject private var vm = SettingsViewModel()
    @EnvironmentObject private var appState: AppState
    @AppStorage("klarityShowMenuBar") private var showMenuBarItem: Bool = true

    var body: some View {
        Form {
            // ── Appearance ───────────────────────────────────────────────────
            Section("Appearance") {
                Picker("Color Scheme", selection: $appState.colorSchemePreference) {
                    Text("System (follow macOS)").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.radioGroup)

                Toggle("Show Klarity in menu bar", isOn: $showMenuBarItem)
                    .help("Shows a menu bar icon for quick access to recording controls without opening the app.")
            }

            // ── System Requirements ──────────────────────────────────────────
            Section {
                if appState.dependencies == nil {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Checking dependencies…")
                            .foregroundStyle(.secondary)
                            .font(AppTheme.Fonts.body)
                    }
                } else if let deps = appState.dependencies {
                    ForEach(deps.checks) { check in
                        LabeledContent(check.name) {
                            HStack(spacing: 6) {
                                Image(systemName: check.isOk ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(check.isOk ? Color.green : (check.required ? Color.red : Color.orange))
                                Text(check.detail)
                                    .font(AppTheme.Fonts.caption)
                                    .foregroundStyle(check.isOk ? .secondary : (check.required ? Color.red : Color.orange))
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Button {
                    Task { await appState.checkDependencies() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                        .font(AppTheme.Fonts.caption)
                }
                .buttonStyle(.bordered)
            } header: {
                Text("System Requirements")
            } footer: {
                if let deps = appState.dependencies, !deps.allRequiredOk {
                    Text("⚠ One or more required dependencies are missing. Recording and transcription will fail until resolved.")
                        .foregroundStyle(.red)
                }
            }

            Section("Transcription") {
                Picker("Provider", selection: $vm.settings.defaultTranscriptionProvider) {
                    Text("ElevenLabs Scribe").tag("elevenlabs")
                }
                SecureField("ElevenLabs API Key", text: $vm.settings.elevenLabsApiKey)
                    .help("Get your key from elevenlabs.io/api")
            }

            Section("LLM Provider") {
                Picker("Provider", selection: $vm.settings.defaultLlmProvider) {
                    Text("Ollama (Local)").tag("ollama")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                    Text("Gemini").tag("gemini")
                }
                .onChange(of: vm.settings.defaultLlmProvider) { _, newProvider in
                    // Auto-select the recommended affordable model for the new provider
                    vm.settings.defaultLlmModel = Self.defaultModel(for: newProvider)
                    if newProvider == "ollama" {
                        Task { await vm.loadOllamaModels() }
                    }
                }

                switch vm.settings.defaultLlmProvider {
                case "ollama":
                    if vm.isLoadingOllamaModels {
                        LabeledContent("Model") {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.6)
                                Text("Loading models…").foregroundStyle(.secondary)
                            }
                        }
                    } else if vm.ollamaModels.isEmpty {
                        TextField("Model", text: $vm.settings.defaultLlmModel)
                            .help("Ollama not reachable or no models pulled. Enter a model name manually.")
                    } else {
                        Picker("Model", selection: $vm.settings.defaultLlmModel) {
                            ForEach(vm.ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                case "openai":
                    Picker("Model", selection: $vm.settings.defaultLlmModel) {
                        Text("gpt-4o-mini  (recommended — affordable)").tag("gpt-4o-mini")
                        Text("gpt-4o").tag("gpt-4o")
                        Text("gpt-4-turbo").tag("gpt-4-turbo")
                    }
                case "anthropic":
                    Picker("Model", selection: $vm.settings.defaultLlmModel) {
                        Text("claude-3-5-haiku-20241022  (recommended — affordable)").tag("claude-3-5-haiku-20241022")
                        Text("claude-3-5-sonnet-20241022").tag("claude-3-5-sonnet-20241022")
                        Text("claude-3-opus-20240229").tag("claude-3-opus-20240229")
                    }
                case "gemini":
                    Picker("Model", selection: $vm.settings.defaultLlmModel) {
                        Text("gemini-2.5-flash-lite  (recommended — affordable)").tag("gemini-2.5-flash-lite")
                        Text("gemini-2.5-flash").tag("gemini-2.5-flash")
                        Text("gemini-2.5-pro").tag("gemini-2.5-pro")
                    }
                default:
                    TextField("Model", text: $vm.settings.defaultLlmModel)
                }
            }

            Section("API Keys") {
                SecureField("OpenAI API Key", text: $vm.settings.openAiApiKey)
                SecureField("Anthropic API Key", text: $vm.settings.anthropicApiKey)
                SecureField("Gemini API Key", text: $vm.settings.geminiApiKey)
                TextField("Ollama Endpoint", text: $vm.settings.ollamaEndpoint)
            }

            Section {
                LabeledContent("Google Calendar") {
                    if vm.settings.googleCalendarConnected == true {
                        Button("Disconnect") { disconnectCalendar(.google) }
                            .foregroundStyle(AppTheme.Colors.accentRed)
                    } else {
                        Button("Connect") { Task { await connectCalendar(.google) } }
                    }
                }
                LabeledContent("Outlook / Microsoft 365") {
                    if vm.settings.outlookConnected == true {
                        Button("Disconnect") { disconnectCalendar(.microsoft) }
                            .foregroundStyle(AppTheme.Colors.accentRed)
                    } else {
                        Button("Connect") { Task { await connectCalendar(.microsoft) } }
                    }
                }
            } header: {
                Text("Calendar Sync")
            } footer: {
                Text("Register OAuth apps first: Google Cloud Console (redirect: klarity://oauth/google/callback) and Azure Portal (redirect: klarity://oauth/microsoft/callback). Then add the client IDs to Info.plist as KlarityGoogleClientID / KlarityMicrosoftClientID.")
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                TextField("Storage Directory", text: $vm.settings.baseStorageDir)
                    .help("Base directory where meetings, voices, and exports are stored.")
            }

            Section("Speaker Matching Thresholds") {
                LabeledContent("Suggest match (≥)") {
                    Slider(value: $vm.settings.speakerSuggestThreshold, in: 0.5...1.0, step: 0.01)
                    Text(String(format: "%.2f", vm.settings.speakerSuggestThreshold))
                        .monospacedDigit().frame(width: 40)
                }
                LabeledContent("Auto-assign (≥)") {
                    Slider(value: $vm.settings.speakerAutoAssignThreshold, in: 0.5...1.0, step: 0.01)
                    Text(String(format: "%.2f", vm.settings.speakerAutoAssignThreshold))
                        .monospacedDigit().frame(width: 40)
                }
                LabeledContent("Duplicate detection (≥)") {
                    Slider(value: $vm.settings.speakerDuplicateThreshold, in: 0.5...1.0, step: 0.01)
                    Text(String(format: "%.2f", vm.settings.speakerDuplicateThreshold))
                        .monospacedDigit().frame(width: 40)
                }
            }

            Section {
                @StateObject var permVM = PermissionsViewModel()

                LabeledContent("Microphone") {
                    if permVM.hasMicAccess {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") { permVM.requestMicAccess() }
                            .foregroundStyle(AppTheme.Colors.accentRed)
                    }
                }

                LabeledContent("System Audio Recording") {
                    switch permVM.hasSystemAudioAccess {
                    case .some(true):
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .some(false):
                        Text("Denied — start a recording to re-prompt")
                            .foregroundStyle(AppTheme.Colors.accentRed)
                            .font(AppTheme.Fonts.caption)
                    case .none:
                        Text("Prompted on first recording")
                            .foregroundStyle(.secondary)
                            .font(AppTheme.Fonts.caption)
                    }
                }

                Button(role: .destructive) {
                    permVM.resetPermissions()
                } label: {
                    Label("Reset All Permissions (Restarts App)", systemImage: "arrow.counterclockwise")
                }
                .padding(.top, 4)
                .help("Resets all macOS privacy permissions for Klarity and restarts the app. Use this if permissions appear stuck.")
            } header: {
                Text("Permissions & Privacy")
            } footer: {
                Text("System audio recording uses a purple dot indicator (not screen recording). The permission prompt appears once when you start your first recording.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    if vm.isSaving {
                        ProgressView()
                    } else {
                        Button("Save Settings") {
                            Task { await vm.save() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
            }

            if let err = vm.errorMessage {
                Section {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await vm.load() }
    }

    private func connectCalendar(_ provider: CalendarSource) async {
        do {
            try await CalendarService.shared.authenticate(provider: provider)
            await vm.load()
        } catch {
            // Errors surface in the system browser; silently ignore cancellations
        }
    }

    private func disconnectCalendar(_ provider: CalendarSource) {
        CalendarService.shared.disconnect(provider)
        Task { await vm.load() }
    }

    /// Recommended affordable model for each provider.
    static func defaultModel(for provider: String) -> String {
        switch provider {
        case "openai":    return "gpt-4o-mini"
        case "anthropic": return "claude-3-5-haiku-20241022"
        case "gemini":    return "gemini-2.5-flash-lite"
        default:          return "llama3"
        }
    }
}
