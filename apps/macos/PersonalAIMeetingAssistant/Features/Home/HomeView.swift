import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recordingVM: RecordingViewModel

    @State private var selectedMeetingId: String?
    @State private var depWarningDismissed = false

    // Multi-select
    @State private var selectionMode = false
    @State private var selectedIds = Set<String>()
    @State private var showDeleteConfirm = false

    // Inline rename
    @State private var editingMeetingId: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Dependency warning
                if !depWarningDismissed,
                   let deps = appState.dependencies,
                   !deps.allRequiredOk {
                    depWarningBanner(deps: deps)
                }

                // Toolbar
                toolbar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppTheme.Colors.background)

                Divider().opacity(0.4)

                // Content
                if vm.isLoading && vm.meetings.isEmpty {
                    Spacer()
                    ProgressView().controlSize(.large)
                    Spacer()
                } else if vm.filteredMeetings.isEmpty {
                    emptyState
                } else {
                    meetingList
                }
            }
            .background(AppTheme.Colors.background)
            .navigationDestination(item: $selectedMeetingId) { id in
                MeetingDetailView(meetingId: id)
            }
            // Navigate to newly completed recording
            .onChange(of: recordingVM.completedMeeting) { _, meeting in
                guard let m = meeting else { return }
                vm.insertMeeting(m)
                selectedMeetingId = m.id
                recordingVM.completedMeeting = nil
                Task { await vm.load() }
            }
            // Clear selection when a meeting is deleted
            .onChange(of: vm.deletedMeetingId) { _, deletedId in
                guard let deletedId else { return }
                if selectedMeetingId == deletedId {
                    selectedMeetingId = nil
                }
                vm.deletedMeetingId = nil
            }
            .confirmationDialog(
                "Delete \(selectedIds.count) meeting\(selectedIds.count == 1 ? "" : "s")?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { Task { await bulkDelete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            // Load on the VStack level — more reliable than NavigationStack.task
            // in a macOS NavigationSplitView detail pane.
            .task { await vm.load() }
            .onAppear { if vm.meetings.isEmpty { Task { await vm.load() } } }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            if selectionMode {
                // Selection mode toolbar
                Button("Done") {
                    selectionMode = false
                    selectedIds = []
                }
                .font(AppTheme.Fonts.listTitle)
                .foregroundStyle(AppTheme.Colors.brandPrimary)

                Spacer()

                if !selectedIds.isEmpty {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete (\(selectedIds.count))", systemImage: "trash")
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(AppTheme.Colors.accentRed)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AppTheme.Colors.accentRed.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Normal toolbar
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .font(.system(size: 13))
                    TextField("Search meetings…", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .font(AppTheme.Fonts.body)
                    if !vm.searchText.isEmpty {
                        Button { vm.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AppTheme.Colors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                    .stroke(AppTheme.Colors.border, lineWidth: 0.5))

                Spacer()

                if !vm.filteredMeetings.isEmpty {
                    Button {
                        selectionMode = true
                    } label: {
                        Text("Select")
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(AppTheme.Colors.brandPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AppTheme.Colors.brandLight)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Meeting List

    private var meetingList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(vm.filteredMeetings) { meeting in
                    MeetingRowView(
                        meeting: meeting,
                        isSelected: selectedIds.contains(meeting.id),
                        selectionMode: selectionMode,
                        isEditing: Binding(
                            get: { editingMeetingId == meeting.id },
                            set: { v in editingMeetingId = v ? meeting.id : nil }
                        ),
                        onTap: {
                            if selectionMode {
                                if selectedIds.contains(meeting.id) {
                                    selectedIds.remove(meeting.id)
                                } else {
                                    selectedIds.insert(meeting.id)
                                }
                            } else {
                                selectedMeetingId = meeting.id
                            }
                        },
                        onRename: { title in
                            Task { await vm.renameMeeting(meeting, title: title) }
                        }
                    )
                    .contextMenu {
                        if !selectionMode {
                            Button {
                                editingMeetingId = meeting.id
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button {
                                selectionMode = true
                                selectedIds = [meeting.id]
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                        }
                        if meeting.status == .failed {
                            Button {
                                Task { await vm.retryMeeting(meeting) }
                            } label: {
                                Label("Retry Transcription", systemImage: "arrow.clockwise")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            Task { await vm.deleteMeeting(meeting) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(AppTheme.Colors.background)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(AppTheme.Colors.brandLight).frame(width: 72, height: 72)
                Image(systemName: "mic.fill").font(.system(size: 28)).foregroundStyle(AppTheme.Colors.brandPrimary)
            }
            Text(vm.searchText.isEmpty ? "No meetings yet" : "No results for \"\(vm.searchText)\"")
                .font(AppTheme.Fonts.title).foregroundStyle(AppTheme.Colors.primaryText)
            Text(vm.searchText.isEmpty
                 ? "Use the \"New Recording\" button above to start capturing a meeting."
                 : "Try a different search term.")
                .font(AppTheme.Fonts.body).foregroundStyle(AppTheme.Colors.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bulk delete

    private func bulkDelete() async {
        for id in selectedIds {
            if let m = vm.meetings.first(where: { $0.id == id }) {
                await vm.deleteMeeting(m)
            }
        }
        selectedIds = []
        selectionMode = false
    }

    // MARK: - Dependency warning

    private func depWarningBanner(deps: DependenciesResult) -> some View {
        let failing = deps.checks.filter { !$0.isOk && $0.required }
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Colors.accentOrange).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text("Setup incomplete").font(AppTheme.Fonts.listTitle).foregroundStyle(AppTheme.Colors.primaryText)
                Text(failing.map(\.name).joined(separator: ", ") + " not configured.")
                    .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.secondaryText)
            }
            Spacer()
            Button("Open Settings") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                .font(AppTheme.Fonts.caption).buttonStyle(.bordered)
            Button { depWarningDismissed = true } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(AppTheme.Colors.accentOrange.opacity(0.07))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(AppTheme.Colors.accentOrange.opacity(0.2)), alignment: .bottom)
    }
}

// MARK: - Meeting Row

struct MeetingRowView: View {
    let meeting: Meeting
    let isSelected: Bool
    let selectionMode: Bool
    @Binding var isEditing: Bool
    let onTap: () -> Void
    let onRename: (String) -> Void

    @State private var isHovered = false
    @State private var editTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                editingRow
            } else {
                Button(action: onTap) {
                    rowContent
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHovered)
            }
        }
        .onChange(of: isEditing) { _, editing in
            if editing {
                editTitle = meeting.title
            }
        }
    }

    // MARK: Normal row

    private var rowContent: some View {
        HStack(spacing: 12) {
            // Selection checkbox or icon
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? AppTheme.Colors.brandPrimary : AppTheme.Colors.tertiaryText)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(iconBg)
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(iconFg)
                }
            }

            // Title + metadata
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(meeting.title)
                        .font(AppTheme.Fonts.listTitle)
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .lineLimit(1)

                    if isHovered && !selectionMode {
                        Button {
                            isEditing = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Rename meeting")
                    }
                }

                HStack(spacing: 5) {
                    Text(relativeDate(meeting.createdAt))
                    if let dur = meeting.durationSeconds, dur > 0 {
                        Text("·")
                        Text(formatDuration(Int(dur)))
                    }
                }
                .font(AppTheme.Fonts.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            }

            Spacer(minLength: 8)

            // People avatars
            if !meeting.speakersPreview.isEmpty {
                peopleAvatars
            }

            // Status pill
            statusView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                .fill(isSelected
                      ? AppTheme.Colors.brandLight
                      : (isHovered ? AppTheme.Colors.hoverFill : Color.clear))
        )
        .contentShape(Rectangle())
    }

    // MARK: Editing row

    private var editingRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(iconBg)
                    .frame(width: 36, height: 36)
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconFg)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    TextField("Meeting title", text: $editTitle)
                        .textFieldStyle(.plain)
                        .font(AppTheme.Fonts.listTitle)
                        .focused($titleFocused)
                        .onSubmit { commitRename() }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused { commitRename() }
                        }

                    Button { commitRename() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(AppTheme.Colors.brandPrimary)
                    }
                    .buttonStyle(.plain)

                    Button { isEditing = false } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(AppTheme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 5) {
                    Text(relativeDate(meeting.createdAt))
                    if let dur = meeting.durationSeconds, dur > 0 {
                        Text("·")
                        Text(formatDuration(Int(dur)))
                    }
                }
                .font(AppTheme.Fonts.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                .fill(AppTheme.Colors.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                        .stroke(AppTheme.Colors.brandPrimary.opacity(0.4), lineWidth: 1)
                )
        )
        .onAppear { titleFocused = true }
    }

    private func commitRename() {
        let trimmed = editTitle.trimmingCharacters(in: .whitespaces)
        isEditing = false
        guard !trimmed.isEmpty, trimmed != meeting.title else { return }
        onRename(trimmed)
    }

    // MARK: People avatars

    private var peopleAvatars: some View {
        let names = Array(meeting.speakersPreview.prefix(3))
        let extra = meeting.speakersPreview.count - names.count
        return HStack(spacing: -6) {
            ForEach(Array(names.enumerated()), id: \.offset) { idx, name in
                ZStack {
                    Circle()
                        .fill(avatarColor(for: name))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(AppTheme.Colors.background, lineWidth: 1.5))
                    Text(initials(for: name))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .zIndex(Double(names.count - idx))
            }
            if extra > 0 {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.inputBackground)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(AppTheme.Colors.background, lineWidth: 1.5))
                    Text("+\(extra)")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusView: some View {
        switch meeting.status {
        case .preprocessing, .transcribing, .matchingSpeakers:
            activePill(label: meeting.status.displayName, color: AppTheme.Colors.brandPrimary)
        case .summarizing:
            activePill(label: "Summarizing", color: AppTheme.Colors.accentOrange)
        case .transcriptReady:
            staticPill(label: "Transcript ready", color: AppTheme.Colors.brandPrimary)
        case .complete:
            staticPill(label: "Complete", color: AppTheme.Colors.accentGreen)
        case .failed:
            staticPill(label: "Failed", color: AppTheme.Colors.accentRed)
        default:
            EmptyView()
        }
    }

    private func activePill(label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            ProgressView().scaleEffect(0.55).frame(width: 10, height: 10)
            Text(label).font(AppTheme.Fonts.caption).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.10)).clipShape(Capsule())
    }

    private func staticPill(label: String, color: Color) -> some View {
        Text(label).font(AppTheme.Fonts.caption).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.10)).clipShape(Capsule())
    }

    // MARK: Helpers

    private var iconName: String {
        switch meeting.status {
        case .failed: return "exclamationmark.triangle"
        case .complete: return "checkmark.circle.fill"
        default: return "mic.fill"
        }
    }
    private var iconBg: Color {
        switch meeting.status {
        case .failed: return AppTheme.Colors.accentRed.opacity(0.10)
        case .complete: return AppTheme.Colors.accentGreen.opacity(0.10)
        default: return AppTheme.Colors.brandLight
        }
    }
    private var iconFg: Color {
        switch meeting.status {
        case .failed: return AppTheme.Colors.accentRed
        case .complete: return AppTheme.Colors.accentGreen
        default: return AppTheme.Colors.brandPrimary
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "h:mm a"; return "Today, \(f.string(from: date))"
        }
        if cal.isDateInYesterday(date) {
            let f = DateFormatter(); f.dateFormat = "h:mm a"; return "Yesterday, \(f.string(from: date))"
        }
        let f = DateFormatter()
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: Date()) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    private func formatDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        let h = seconds / 3600; let m = (seconds % 3600) / 60; let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s > 0 ? "\(s)s" : "")" }
        return "\(s)s"
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(name.prefix(1)).uppercased()
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.indigo, .teal,
            Color(red: 0.85, green: 0.35, blue: 0.25),
            Color(red: 0.25, green: 0.65, blue: 0.55),
            .purple,
            Color(red: 0.70, green: 0.45, blue: 0.10)]
        return colors[abs(name.hashValue) % colors.count]
    }
}
