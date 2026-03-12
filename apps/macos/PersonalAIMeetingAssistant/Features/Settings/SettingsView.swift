import SwiftUI

struct SettingsView: View {
    @StateObject private var vm = SettingsViewModel()
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
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
                Picker("Default Provider", selection: $vm.settings.defaultLlmProvider) {
                    Text("Ollama (Local)").tag("ollama")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                    Text("Gemini").tag("gemini")
                }
                TextField("Default Model", text: $vm.settings.defaultLlmModel)
            }

            Section("API Keys") {
                SecureField("OpenAI API Key", text: $vm.settings.openAiApiKey)
                SecureField("Anthropic API Key", text: $vm.settings.anthropicApiKey)
                SecureField("Gemini API Key", text: $vm.settings.geminiApiKey)
                TextField("Ollama Endpoint", text: $vm.settings.ollamaEndpoint)
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

            Section("Permissions & Privacy") {
                @StateObject var permVM = PermissionsViewModel()
                
                LabeledContent("Microphone Access") {
                    if permVM.hasMicAccess {
                        Text("Granted").foregroundStyle(.green)
                    } else {
                        Button("Request") { permVM.requestMicAccess() }
                    }
                }
                
                LabeledContent("Screen & System Audio") {
                    if permVM.hasScreenAccess {
                        Text("Granted").foregroundStyle(.green)
                    } else {
                        Button("Request") { permVM.requestScreenAccess() }
                    }
                }
                
                Button(role: .destructive) {
                    permVM.resetPermissions()
                } label: {
                    Label("Reset All Permissions (Restarts App)", systemImage: "arrow.counterclockwise")
                }
                .padding(.top, 4)
                .help("If macOS keeps asking for permissions but doesn't register them, click this to reset the privacy database for Klarity.")
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
}
