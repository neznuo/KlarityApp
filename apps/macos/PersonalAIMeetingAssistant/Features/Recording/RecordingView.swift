import SwiftUI

/// Pre-recording setup sheet — enter title, pick mode, start.
/// Once recording starts the sheet dismisses and the global RecordingStatusPill takes over.
struct RecordingView: View {
    @EnvironmentObject var vm: RecordingViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var calendarVM = CalendarViewModel()
    @State private var selectedEvent: CalendarEvent?

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            HStack {
                Text("New Recording")
                    .font(AppTheme.Fonts.title)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .padding(6)
                        .background(AppTheme.Colors.hoverFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider().opacity(0.4)

            // ── Form ──────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 20) {

                // Calendar event pills (only when at least one calendar is connected)
                if calendarVM.hasAnyCalendarConnected && !calendarVM.upcomingEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Upcoming")
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .textCase(.uppercase)
                            .kerning(0.3)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(calendarVM.upcomingEvents) { event in
                                    CalendarEventPill(
                                        event: event,
                                        isSelected: selectedEvent?.id == event.id
                                    ) {
                                        selectedEvent = event
                                        vm.meetingTitle = event.title
                                    }
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }

                // Title field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Meeting Title")
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .textCase(.uppercase)
                        .kerning(0.3)
                    TextField("e.g. Product Sync, 1:1 with Sarah", text: $vm.meetingTitle)
                        .textFieldStyle(.plain)
                        .font(AppTheme.Fonts.body)
                        .padding(10)
                        .background(AppTheme.Colors.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                            .stroke(AppTheme.Colors.border, lineWidth: 0.5))
                        .onSubmit { startIfReady() }
                }

                // Recording mode
                VStack(alignment: .leading, spacing: 6) {
                    Text("Capture Mode")
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .textCase(.uppercase)
                        .kerning(0.3)
                    Picker("", selection: $vm.recordingMode) {
                        ForEach(RecordingMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(24)

            Spacer(minLength: 0)

            Divider().opacity(0.4)

            // ── Footer: error + actions ───────────────────────────────────────
            VStack(spacing: 12) {
                if let err = vm.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(AppTheme.Colors.accentRed)
                            .font(.system(size: 13))
                        Text(err)
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(AppTheme.Colors.accentRed)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                }

                HStack(spacing: 10) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.plain)
                        .font(AppTheme.Fonts.body)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(AppTheme.Colors.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                            .stroke(AppTheme.Colors.border, lineWidth: 0.5))

                    Spacer()

                    if vm.isCreating || vm.isPreparing {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text(vm.isCreating ? "Starting…" : "Preparing…")
                                .font(AppTheme.Fonts.body)
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    } else {
                        Button { startIfReady() } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                Text("Start Recording")
                                    .font(AppTheme.Fonts.listTitle)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(vm.meetingTitle.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? AppTheme.Colors.brandPrimary.opacity(0.4)
                                        : AppTheme.Colors.brandPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.meetingTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 12)
            }
        }
        .frame(width: 440)
        .background(AppTheme.Colors.background)
        .task { await calendarVM.loadEvents() }
        // Dismiss as soon as recording is confirmed active — status pill takes over
        .onChange(of: vm.isRecording) { _, isRecording in
            if isRecording { dismiss() }
        }
        // Clear event selection when user manually edits the title away from the event title
        .onChange(of: vm.meetingTitle) { _, newValue in
            if let selected = selectedEvent, newValue != selected.title {
                selectedEvent = nil
            }
        }
    }

    private func startIfReady() {
        guard !vm.meetingTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await vm.startNewMeeting(
                calendarEventId: selectedEvent?.id,
                calendarSource: selectedEvent?.calendarSource.rawValue
            )
        }
    }
}

// MARK: - CalendarEventPill

private struct CalendarEventPill: View {
    let event: CalendarEvent
    let isSelected: Bool
    let action: () -> Void

    private var timeLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: event.startDate)
    }

    private var providerIcon: String {
        switch event.calendarSource {
        case .google:    return "calendar"
        case .microsoft: return "calendar.badge.clock"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: providerIcon)
                    .font(.system(size: 11))
                Text(event.title)
                    .font(AppTheme.Fonts.caption)
                    .lineLimit(1)
                Text("·")
                    .font(AppTheme.Fonts.caption)
                    .opacity(0.5)
                Text(timeLabel)
                    .font(AppTheme.Fonts.caption)
                    .opacity(0.7)
            }
            .foregroundStyle(isSelected ? .white : AppTheme.Colors.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? AppTheme.Colors.brandPrimary : AppTheme.Colors.inputBackground)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(
                isSelected ? AppTheme.Colors.brandPrimary : AppTheme.Colors.border,
                lineWidth: 0.5
            ))
        }
        .buttonStyle(.plain)
    }
}
