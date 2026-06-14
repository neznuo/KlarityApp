import SwiftUI

// MARK: - ChatView

struct ChatView: View {
    @StateObject private var vm = ChatViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Provider / Model picker bar ───────────────────────────────────
            providerBar

            Divider()

            // ── Message list ──────────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if vm.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(vm.messages) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    if let last = vm.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                // Also scroll as tokens stream in (content changes on last message)
                .onChange(of: vm.messages.last?.content) { _, _ in
                    if let last = vm.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // ── Input bar ─────────────────────────────────────────────────────
            inputBar
        }
        .background(AppTheme.Colors.background)
    }

    // MARK: - Provider Bar

    private var providerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(AppTheme.Colors.brandPrimary)
                .font(.system(size: 13, weight: .semibold))

            Text("AI Assistant")
                .font(AppTheme.Fonts.listTitle)
                .foregroundStyle(AppTheme.Colors.primaryText)

            Spacer()

            // Provider picker
            Picker("", selection: $vm.selectedProvider) {
                ForEach(vm.providers, id: \.id) { p in
                    Text(p.label).tag(p.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .onChange(of: vm.selectedProvider) { _, _ in vm.onProviderChanged() }

            // Model text field
            TextField("Model", text: $vm.selectedModel)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .font(AppTheme.Fonts.caption)
                .help("Leave blank to use the provider's default model")

            // Clear button
            Button {
                vm.clearConversation()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }
            .buttonStyle(.borderless)
            .help("Clear conversation")
            .disabled(vm.messages.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.Colors.cardSurface)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 60)

            ZStack {
                Circle()
                    .fill(AppTheme.Colors.brandLight)
                    .frame(width: 72, height: 72)
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 30))
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
            }

            VStack(spacing: 8) {
                Text("Ask Klarity anything about your meetings")
                    .font(AppTheme.Fonts.title)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .multilineTextAlignment(.center)

                Text("Try asking about tasks, decisions, or what was discussed in past meetings.")
                    .font(AppTheme.Fonts.body)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            // Suggestion chips
            VStack(spacing: 8) {
                SuggestionChip(text: "What tasks do I have open?") {
                    vm.inputText = "What tasks do I have open?"
                    Task { await vm.sendMessage() }
                }
                SuggestionChip(text: "What was decided in the last meeting?") {
                    vm.inputText = "What was decided in the last meeting?"
                    Task { await vm.sendMessage() }
                }
                SuggestionChip(text: "Tasks assigned to me in the last 30 days") {
                    vm.inputText = "What are all the tasks assigned to me in the last 30 days?"
                    Task { await vm.sendMessage() }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about your meetings, tasks, decisions…", text: $vm.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(AppTheme.Fonts.body)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.Colors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                        .stroke(inputFocused ? AppTheme.Colors.brandPrimary.opacity(0.6)
                                             : AppTheme.Colors.subtleBorder, lineWidth: 1)
                )
                .onSubmit {
                    if !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task { await vm.sendMessage() }
                    }
                }

            Button {
                Task { await vm.sendMessage() }
            } label: {
                if vm.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(
                            vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AppTheme.Colors.tertiaryText
                                : AppTheme.Colors.brandPrimary
                        )
                }
            }
            .buttonStyle(.borderless)
            .disabled(vm.isLoading || vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.cardSurface)
    }
}

// MARK: - Chat Bubble

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 80) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if message.role == .assistant {
                        avatarIcon
                    }
                    Text(message.role == .user ? "You" : "Klarity")
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                    if message.role == .user {
                        avatarIcon
                    }
                }

                ZStack(alignment: .bottomTrailing) {
                    Text(message.content.isEmpty ? "  " : message.content)
                        .font(AppTheme.Fonts.body)
                        .foregroundStyle(
                            message.role == .user
                                ? Color.white
                                : AppTheme.Colors.primaryText
                        )
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            message.role == .user
                                ? AppTheme.Colors.brandPrimary
                                : AppTheme.Colors.cardSurface
                        )
                        .clipShape(bubbleShape(for: message.role))
                        .overlay(
                            bubbleShape(for: message.role)
                                .stroke(
                                    message.role == .assistant
                                        ? AppTheme.Colors.subtleBorder
                                        : Color.clear,
                                    lineWidth: 0.5
                                )
                        )

                    if message.isStreaming {
                        TypingIndicator()
                            .padding(.trailing, 10)
                            .padding(.bottom, 8)
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 80) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var avatarIcon: some View {
        Group {
            if message.role == .assistant {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.brandLight)
                        .frame(width: 24, height: 24)
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.brandPrimary)
                }
            } else {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.hoverFill)
                        .frame(width: 24, height: 24)
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }
        }
    }

    private func bubbleShape(for role: ChatMessage.Role) -> some Shape {
        role == .user
            ? UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                     bottomTrailingRadius: 4, topTrailingRadius: 16)
            : UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 16,
                                     bottomTrailingRadius: 16, topTrailingRadius: 16)
    }
}

// MARK: - Typing Indicator (animated dots)

private struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(AppTheme.Colors.tertiaryText)
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase == i ? 1.4 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .onAppear {
            phase = 1
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - Suggestion Chip

private struct SuggestionChip: View {
    let text: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
                Text(text)
                    .font(AppTheme.Fonts.body)
                    .foregroundStyle(AppTheme.Colors.primaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                hovered
                    ? AppTheme.Colors.brandLight
                    : AppTheme.Colors.cardSurface
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(AppTheme.Colors.subtleBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.borderless)
        .onHover { hovered = $0 }
    }
}
