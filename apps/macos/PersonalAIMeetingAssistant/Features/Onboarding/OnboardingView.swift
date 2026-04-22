import SwiftUI

struct OnboardingView: View {
    @AppStorage("klarityHasCompletedOnboarding") private var onboardingCompleted = true
    @StateObject private var permVM = PermissionsViewModel()
    @StateObject private var settingsVM = SettingsViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var currentStep = 0

    private let steps = OnboardingStep.allCases

    var body: some View {
        OnboardingStepContainer(
            stepIndex: currentStep,
            totalSteps: steps.count,
            canContinue: canContinue,
            continueLabel: continueLabel,
            showSkip: steps[currentStep].canSkip,
            onBack: { withAnimation { currentStep = max(0, currentStep - 1) } },
            onContinue: { advance() },
            onSkip: steps[currentStep].canSkip ? { advance() } : nil
        ) {
            switch steps[currentStep] {
            case .welcome:     welcomeStep
            case .permissions: permissionsStep
            case .apiKeys:     apiKeysStep
            case .calendar:    calendarStep
            case .done:        doneStep
            }
        }
        .task { await settingsVM.load() }
    }

    private var canContinue: Bool {
        switch steps[currentStep] {
        case .welcome:     return true
        case .permissions: return permVM.hasMicAccess
        case .apiKeys:     return true
        case .calendar:   return true
        case .done:        return true
        }
    }

    private var continueLabel: String {
        switch steps[currentStep] {
        case .welcome:     return "Get Started"
        case .permissions: return "Continue"
        case .apiKeys:     return "Continue"
        case .calendar:    return "Continue"
        case .done:        return "Start Using Klarity"
        }
    }

    private func advance() {
        if currentStep < steps.count - 1 {
            withAnimation { currentStep += 1 }
        } else {
            onboardingCompleted = true
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

            Text("Welcome to Klarity")
                .font(AppTheme.Fonts.header)
                .foregroundStyle(AppTheme.Colors.primaryText)

            Text("Your personal AI meeting assistant.\nRecord meetings locally, get transcripts, speaker identification, and structured notes — all on your Mac.")
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Spacer()
        }
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Text("Grant Permissions")
                .font(AppTheme.Fonts.header)
                .foregroundStyle(AppTheme.Colors.primaryText)

            Text("Klarity needs a few permissions to record meetings and detect calls.")
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)

            PermissionsDashboardView(permVM: permVM, compact: false)
                .padding(.horizontal, 4)

            if !permVM.hasMicAccess {
                Text("Microphone access is required to continue.")
                    .font(AppTheme.Fonts.caption)
                    .foregroundStyle(AppTheme.Colors.accentOrange)
            }

            Spacer()
        }
        .onAppear { permVM.checkAll() }
    }

    // MARK: - API Keys

    private var apiKeysStep: some View {
        VStack(spacing: 16) {
            Text("Configure API Keys")
                .font(AppTheme.Fonts.header)
                .foregroundStyle(AppTheme.Colors.primaryText)

            Text("Klarity uses cloud services for transcription and note generation. You can add these later in Settings.")
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                SecureField("ElevenLabs API Key", text: $settingsVM.settings.elevenLabsApiKey)
                    .textFieldStyle(.roundedBorder)

                Picker("LLM Provider", selection: $settingsVM.settings.defaultLlmProvider) {
                    Text("Ollama (Local)").tag("ollama")
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                    Text("Gemini").tag("gemini")
                }

                switch settingsVM.settings.defaultLlmProvider {
                case "openai":
                    SecureField("OpenAI API Key", text: $settingsVM.settings.openAiApiKey)
                        .textFieldStyle(.roundedBorder)
                case "anthropic":
                    SecureField("Anthropic API Key", text: $settingsVM.settings.anthropicApiKey)
                        .textFieldStyle(.roundedBorder)
                case "gemini":
                    SecureField("Gemini API Key", text: $settingsVM.settings.geminiApiKey)
                        .textFieldStyle(.roundedBorder)
                case "ollama":
                    TextField("Ollama Endpoint", text: $settingsVM.settings.ollamaEndpoint)
                        .textFieldStyle(.roundedBorder)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 4)

            Spacer()
        }
    }

    // MARK: - Calendar

    private var calendarStep: some View {
        VStack(spacing: 16) {
            Text("Connect Your Calendar")
                .font(AppTheme.Fonts.header)
                .foregroundStyle(AppTheme.Colors.primaryText)

            Text("Connect Google Calendar or Outlook to see upcoming meetings and auto-detect when to record.")
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                calendarRow(
                    icon: "calendar",
                    title: "Google Calendar",
                    isOn: settingsVM.settings.googleCalendarConnected == true
                ) {
                    Task { try? await CalendarService.shared.authenticate(provider: .google); await settingsVM.load(); permVM.checkCalendarAccess() }
                } disconnect: {
                    CalendarService.shared.disconnect(.google); Task { await settingsVM.load(); }; permVM.checkCalendarAccess()
                }

                calendarRow(
                    icon: "calendar.badge.clock",
                    title: "Outlook / Microsoft 365",
                    isOn: settingsVM.settings.outlookConnected == true
                ) {
                    Task { try? await CalendarService.shared.authenticate(provider: .microsoft); await settingsVM.load(); permVM.checkCalendarAccess() }
                } disconnect: {
                    CalendarService.shared.disconnect(.microsoft); Task { await settingsVM.load(); }; permVM.checkCalendarAccess()
                }
            }
            .padding(.horizontal, 4)

            Spacer()
        }
    }

    private func calendarRow(icon: String, title: String, isOn: Bool,
                              connect: @escaping () -> Void, disconnect: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(AppTheme.Colors.brandLight)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
            }
            Text(title)
                .font(AppTheme.Fonts.listTitle)
                .foregroundStyle(AppTheme.Colors.primaryText)
            Spacer()
            if isOn {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Colors.accentGreen)
                    .font(AppTheme.Fonts.caption)
                Button("Disconnect") { disconnect() }
                    .foregroundStyle(AppTheme.Colors.accentRed)
                    .font(AppTheme.Fonts.caption)
            } else {
                Button("Connect") { connect() }
                    .font(AppTheme.Fonts.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                .fill(AppTheme.Colors.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                .stroke(AppTheme.Colors.subtleBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle().fill(AppTheme.Colors.brandLight).frame(width: 72, height: 72)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(AppTheme.Colors.accentGreen)
            }

            Text("You're all set!")
                .font(AppTheme.Fonts.header)
                .foregroundStyle(AppTheme.Colors.primaryText)

            Text(permVM.readinessText)
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)

            if !permVM.hasMicAccess {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Colors.accentOrange)
                    Text("Microphone access is still missing — recording won't work until granted.")
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.accentOrange)
                }
                .frame(maxWidth: 420)
            }

            Text("You can always change these in Settings later.")
                .font(AppTheme.Fonts.caption)
                .foregroundStyle(AppTheme.Colors.tertiaryText)

            Button {
                Task { await settingsVM.save() }
            } label: {
                Text("Start Using Klarity")
                    .font(AppTheme.Fonts.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(AppTheme.Colors.brandPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }
}

// MARK: - OnboardingStep

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case apiKeys
    case calendar
    case done

    var canSkip: Bool {
        switch self {
        case .welcome, .permissions, .done: return false
        case .apiKeys, .calendar:           return true
        }
    }
}