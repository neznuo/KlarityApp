import SwiftUI

struct UpcomingView: View {
    @StateObject private var vm = UpcomingViewModel()
    @EnvironmentObject private var recordingVM: RecordingViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider().opacity(0.4)

            if !vm.hasAnyCalendarConnected {
                noCalendarState
            } else if vm.isLoadingEvents && vm.upcomingEvents.isEmpty {
                Spacer()
                ProgressView("Loading events\u{2026}")
                Spacer()
            } else if let error = vm.errorMessage {
                errorState(message: error)
            } else if vm.upcomingEvents.isEmpty {
                emptyState
            } else {
                eventsList
            }
        }
        .background(AppTheme.Colors.background)
        .navigationTitle("Upcoming")
        .task { await vm.loadEvents() }
        .onAppear { vm.startAutoRefresh() }
        .onDisappear { vm.stopAutoRefresh() }
        .refreshable { await vm.forceLoadEvents() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Upcoming")
                .font(AppTheme.Fonts.title)
                .foregroundStyle(AppTheme.Colors.primaryText)
            Spacer()
            Button {
                Task { await vm.forceLoadEvents() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Refresh events")
        }
    }

    // MARK: - No calendar state

    private var noCalendarState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(AppTheme.Colors.brandLight).frame(width: 72, height: 72)
                Image(systemName: "calendar.badge.plus").font(.system(size: 28))
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
            }
            Text("No calendar connected")
                .font(AppTheme.Fonts.title)
                .foregroundStyle(AppTheme.Colors.primaryText)
            Text("Connect Google Calendar or Outlook in Settings to see your upcoming meetings here.")
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Open Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(AppTheme.Colors.brandLight).frame(width: 72, height: 72)
                Image(systemName: "calendar").font(.system(size: 28))
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
            }
            Text("No upcoming meetings")
                .font(AppTheme.Fonts.title)
                .foregroundStyle(AppTheme.Colors.primaryText)
            Text("Your next 24 hours are free. Meetings from Google Calendar and Outlook will appear here automatically.")
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error state

    private func errorState(message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Could not load events")
                .font(AppTheme.Fonts.title)
                .foregroundStyle(AppTheme.Colors.primaryText)
            Text(message)
                .font(AppTheme.Fonts.body)
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Retry") {
                Task { await vm.forceLoadEvents() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Events list

    private var eventsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(vm.upcomingEvents) { event in
                    UpcomingEventCard(event: event, vm: vm, recordingVM: recordingVM)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Event Card

private struct UpcomingEventCard: View {
    let event: CalendarEvent
    @ObservedObject var vm: UpcomingViewModel
    @ObservedObject var recordingVM: RecordingViewModel

    @State private var isHovered = false

    private var providerIcon: String {
        switch event.calendarSource {
        case .google:    return "calendar"
        case .microsoft: return "calendar.badge.clock"
        }
    }

    private var providerLabel: String {
        switch event.calendarSource {
        case .google:    return "Google"
        case .microsoft: return "Outlook"
        }
    }

    private var timeRange: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return "\(fmt.string(from: event.startDate)) - \(fmt.string(from: event.endDate))"
    }

    private var relativeTime: String {
        let delta = event.startDate.timeIntervalSince(Date())
        if delta > 0 {
            if delta < 60 { return "Starts now" }
            let mins = Int(delta / 60)
            if mins < 60 { return "In \(mins) min" }
            let hrs = mins / 60; let rem = mins % 60
            return rem == 0 ? "In \(hrs) hr" : "In \(hrs) hr \(rem) min"
        } else {
            let elapsed = -delta
            let mins = Int(elapsed / 60)
            if mins < 1 { return "Started just now" }
            if mins < 60 { return "Started \(mins) min ago" }
            return "Started \(mins / 60) hr ago"
        }
    }

    private var relativeTimeColor: Color {
        let delta = event.startDate.timeIntervalSince(Date())
        if delta < 0 { return AppTheme.Colors.accentRed }
        if delta < 300 { return AppTheme.Colors.accentOrange }
        return AppTheme.Colors.secondaryText
    }

    private var hasMeetingUrl: Bool { event.onlineMeetingUrl != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(AppTheme.Colors.brandLight)
                    .frame(width: 36, height: 36)
                Image(systemName: providerIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(AppTheme.Fonts.listTitle)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(timeRange)
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                    Text(providerLabel)
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                    if hasMeetingUrl {
                        Image(systemName: "video.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.Colors.accentGreen)
                    }
                }

                Text(relativeTime)
                    .font(AppTheme.Fonts.caption)
                    .foregroundStyle(relativeTimeColor)
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                if hasMeetingUrl {
                    Button {
                        Task { await vm.joinAndRecord(event: event, recordingVM: recordingVM) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 12))
                            Text("Join + Record")
                                .font(AppTheme.Fonts.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppTheme.Colors.brandPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                    }
                    .buttonStyle(.plain)
                    .disabled(recordingVM.isRecording || recordingVM.isCreating)

                    Button {
                        if let urlStr = event.onlineMeetingUrl, let url = URL(string: urlStr) {
                            vm.joinMeeting(url: url)
                        }
                    } label: {
                        Text("Join")
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(AppTheme.Colors.brandPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AppTheme.Colors.brandLight)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await vm.recordOnly(event: event, recordingVM: recordingVM) }
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("Record")
                                .font(AppTheme.Fonts.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppTheme.Colors.brandPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                    }
                    .buttonStyle(.plain)
                    .disabled(recordingVM.isRecording || recordingVM.isCreating)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                .fill(isHovered ? AppTheme.Colors.hoverFill : AppTheme.Colors.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                .stroke(AppTheme.Colors.subtleBorder, lineWidth: 0.5)
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}