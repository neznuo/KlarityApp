import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// The main meeting detail page: tabbed Transcript / Summary with persistent audio player.
struct MeetingDetailView: View {
    let meetingId: String

    @StateObject private var vm = MeetingDetailViewModel()
    @State private var selectedTab: Tab = .transcript
    @State private var playerSeekTarget: Double? = nil

    // Inline title editing
    @State private var isEditingTitle = false
    @State private var editTitle = ""
    @FocusState private var titleFieldFocused: Bool

    enum Tab { case transcript, summary }

    var body: some View {
        VStack(spacing: 0) {
            // ── Custom Top Bar ────────────────────────────────────────────────
            customTopBar
            
            Divider().foregroundStyle(AppTheme.Colors.border)
            
            // ── Tab Navigation ────────────────────────────────────────────────
            HStack(alignment: .bottom, spacing: 0) {
                tabButton(title: "Notes", tab: .summary)
                tabButton(title: "Transcript", tab: .transcript)
                Spacer()
                
                Button {
                    exportCurrentTab()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 10))
                        Text("Export").font(AppTheme.Fonts.caption)
                    }
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppTheme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Export current tab")
                .padding(.trailing, 10)
                
                if selectedTab == .transcript && !vm.speakers.isEmpty {
                    Button {
                        Task { await vm.recomputeSpeakerSuggestions() }
                    } label: {
                        HStack(spacing: 5) {
                            if vm.isRematching {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                            }
                            Text(vm.isRematching ? "Matching…" : "Re-match")
                                .font(AppTheme.Fonts.caption)
                        }
                        .foregroundStyle(AppTheme.Colors.brandPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppTheme.Colors.brandLight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isRematching)
                    .help("Re-run speaker matching against your contacts library")
                }
            }
            .padding(.horizontal, 20)
            .background(AppTheme.Colors.background)

            Divider().opacity(0.4)

            // ── Tab Content ───────────────────────────────────────────────
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()

                switch selectedTab {
                case .transcript:
                    TranscriptView(
                        segments: vm.transcript,
                        speakers: vm.speakers,
                        people: vm.people,
                        status: vm.meeting?.status,
                        onSeek: { ms in playerSeekTarget = Double(ms) / 1000.0 },
                        onAssign: { cluster, person in
                            Task { await vm.assignSpeaker(cluster: cluster, person: person) }
                        },
                        onCreateAndAssign: { cluster, name in
                            Task { await vm.createAndAssign(cluster: cluster, name: name) }
                        },
                        onConfirmSuggestion: { cluster in
                            Task { await vm.confirmSuggestion(cluster: cluster) }
                        },
                        onDismissSuggestion: { cluster in
                            Task { await vm.dismissSuggestion(cluster: cluster) }
                        },
                        onRetry: {
                            Task { await vm.retryProcessing() }
                        }
                    )
                    .overlay {
                        if vm.isRematching {
                            VStack(spacing: 10) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text("Matching speakers…")
                                    .font(AppTheme.Fonts.body)
                                    .foregroundStyle(AppTheme.Colors.secondaryText)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AppTheme.Colors.background.opacity(0.8))
                        }
                    }
                case .summary:
                    SummaryView(
                        summary: vm.summary,
                        tasks: vm.tasks,
                        people: vm.people,
                        speakers: vm.speakers,
                        isSummarizing: vm.isSummarizing,
                        onGenerate: {
                            Task { await vm.generateSummary() }
                        },
                        onTaskToggle: { task in
                            Task { await vm.toggleTaskStatus(task) }
                        },
                        onUpdateOwner: { task, personId in
                            Task { await vm.updateTaskOwner(task: task, personId: personId) }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().foregroundStyle(AppTheme.Colors.border)

            // ── Persistent Audio Player ───────────────────────────────────
            AudioPlayerView(
                audioFilePath: vm.meeting?.audioFilePath,
                seekTarget: $playerSeekTarget
            )
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(AppTheme.Colors.cardBackground)
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .navigation) {
                EmptyView()
            }
        }
        .task { await vm.loadAll(meetingId: meetingId) }
        .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
    
    // MARK: - Subcomponents
    
    private var customTopBar: some View {
        HStack(spacing: 16) {
            // Left: title + metadata
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isEditingTitle {
                        TextField("Meeting title", text: $editTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.primaryText)
                            .focused($titleFieldFocused)
                            .onSubmit { commitTitleEdit() }
                            .onChange(of: titleFieldFocused) { _, focused in
                                if !focused { commitTitleEdit() }
                            }
                        Button { commitTitleEdit() } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.Colors.brandPrimary)
                        }
                        .buttonStyle(.plain)
                        Button { isEditingTitle = false } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(vm.meeting?.title ?? "Loading…")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.primaryText)
                            .lineLimit(1)
                        if vm.meeting?.status.needsPolling == true {
                            ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                        }
                        if vm.meeting != nil {
                            Button {
                                editTitle = vm.meeting?.title ?? ""
                                isEditingTitle = true
                                titleFieldFocused = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .help("Rename meeting")
                        }
                    }
                }

                if let m = vm.meeting {
                    HStack(spacing: 5) {
                        Text(m.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let dur = m.durationSeconds, dur > 0 {
                            Text("·")
                            Text(durationString(Int(dur)))
                        }
                        Text("·")
                        Text(m.status.displayName)
                            .foregroundStyle(statusColor(m.status))
                    }
                    .font(AppTheme.Fonts.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }

            Spacer()

            // Right: summarize CTA
            Button {
                if selectedTab != .summary { selectedTab = .summary }
                Task { await vm.generateSummary() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                    Text(vm.summary == nil ? "Summarize" : "Re-summarize").font(AppTheme.Fonts.listTitle)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(vm.isSummarizing
                    ? AppTheme.Colors.brandPrimary.opacity(0.5)
                    : AppTheme.Colors.brandPrimary)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(vm.isSummarizing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(AppTheme.Colors.background)
    }

    private func commitTitleEdit() {
        let trimmed = editTitle.trimmingCharacters(in: .whitespaces)
        isEditingTitle = false
        guard !trimmed.isEmpty, trimmed != vm.meeting?.title else { return }
        Task { await vm.renameCurrentMeeting(title: trimmed) }
    }

    private func durationString(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        let h = seconds / 3600; let m = (seconds % 3600) / 60; let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s > 0 ? "\(s)s" : "")" }
        return "\(s)s"
    }

    private func statusColor(_ status: MeetingStatus) -> Color {
        switch status {
        case .complete:         return AppTheme.Colors.accentGreen
        case .failed:           return AppTheme.Colors.accentRed
        case .transcriptReady:  return AppTheme.Colors.brandPrimary
        default:                return AppTheme.Colors.secondaryText
        }
    }

    private func tabButton(title: String, tab: Tab) -> some View {
        Button { selectedTab = tab } label: {
            VStack(spacing: 0) {
                Text(title)
                    .font(AppTheme.Fonts.listTitle)
                    .foregroundStyle(selectedTab == tab
                        ? AppTheme.Colors.brandPrimary
                        : AppTheme.Colors.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                // Active underline
                Rectangle()
                    .fill(selectedTab == tab ? AppTheme.Colors.brandPrimary : Color.clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
            .contentShape(Rectangle())   // makes the full padded area hit-testable
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selectedTab)
    }

    // MARK: - Export Logic

    private func exportCurrentTab() {
        let defaultTitle = (vm.meeting?.title ?? "Meeting").replacingOccurrences(of: " ", with: "_")
        let panel = NSSavePanel()
        
        if selectedTab == .transcript {
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "\(defaultTitle)_Transcript.txt"
        } else {
            panel.allowedContentTypes = [.plainText, UTType("net.daringfireball.markdown") ?? .plainText]
            panel.nameFieldStringValue = "\(defaultTitle)_Notes.md"
        }
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        do {
            if selectedTab == .transcript {
                let content = generateTranscriptExport()
                try content.write(to: url, atomically: true, encoding: .utf8)
            } else {
                var content = vm.summary?.summaryMarkdown ?? "No summary available."
                if !vm.tasks.isEmpty {
                    content += "\n\n## Action Items\n"
                    for task in vm.tasks {
                        let statusMarker = task.status.lowercased() == "done" ? "[x]" : "[ ]"
                        let assigneePart = (task.rawOwnerText?.isEmpty == false) ? " (Assignee: \(task.rawOwnerText!))" : ""
                        content += "- \(statusMarker) \(task.description)\(assigneePart)\n"
                    }
                }
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Failed to save export: \(error)")
        }
    }

    private func generateTranscriptExport() -> String {
        var lines: [String] = []
        for segment in vm.transcript {
            let speakerName = resolveSpeakerName(for: segment.clusterId)
            let time = formatExportTimestamp(segment.startMs)
            lines.append("[\(time)] \(speakerName):\n\(segment.text)")
        }
        return lines.joined(separator: "\n\n")
    }

    private func resolveSpeakerName(for clusterId: String?) -> String {
        guard let clusterId = clusterId else { return "Speaker Unknown" }
        guard let cluster = vm.speakers.first(where: { $0.id == clusterId }) else { return "Speaker Unknown" }
        
        if let pid = cluster.assignedPersonId, let match = vm.people.first(where: { $0.id == pid }) {
            return match.displayName
        }
        return cluster.tempLabel
    }

    private func formatExportTimestamp(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Summary Sub-View

struct SummaryView: View {
    let summary: MeetingSummary?
    let tasks: [MeetingTask]
    let people: [Person]
    let speakers: [SpeakerCluster]
    let isSummarizing: Bool
    let onGenerate: () -> Void
    let onTaskToggle: (MeetingTask) -> Void
    let onUpdateOwner: (MeetingTask, String?) -> Void

    var meetingPeople: [Person] {
        let personIds = Set(speakers.compactMap { $0.assignedPersonId })
        return personIds.compactMap { id in people.first { $0.id == id } }
    }

    var body: some View {
        if let summary {
            // Summary exists — show it, with a regenerating banner overlaid when running
            VStack(spacing: 0) {
                if isSummarizing {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.65)
                        Text("Regenerating summary…")
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("This may take a minute.")
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.07))
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.2)), alignment: .bottom)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Header row with regenerate button
                        HStack {
                            Text("Summary")
                                .font(AppTheme.Fonts.caption)
                                .foregroundStyle(AppTheme.Colors.tertiaryText)
                                .textCase(.uppercase)
                                .kerning(0.5)
                            Spacer()
                            if !isSummarizing {
                                Button {
                                    onGenerate()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                                        Text("Regenerate").font(AppTheme.Fonts.caption)
                                    }
                                    .foregroundStyle(AppTheme.Colors.brandPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(AppTheme.Colors.brandLight)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .help("Re-run summarization with the currently configured LLM provider")
                            }
                        }

                        if let md = summary.summaryMarkdown, !md.isEmpty {
                            SelectableMeetingNotesView(markdown: md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .opacity(isSummarizing ? 0.4 : 1)
                        } else {
                            Text("No summary markdown generated.")
                                .foregroundStyle(.secondary)
                        }

                        if !tasks.isEmpty {
                            Divider()
                            Text("Action Items")
                                .font(AppTheme.Fonts.header)
                                .padding(.top, 8)
                            ForEach(tasks) { task in
                                SummaryTaskRowView(
                                    task: task,
                                    meetingPeople: meetingPeople,
                                    isDimmed: isSummarizing,
                                    onToggle: onTaskToggle,
                                    onUpdateOwner: onUpdateOwner
                                )
                            }
                        }
                    }
                    .padding(24)
                }
            }
        } else if isSummarizing {
            // No existing summary yet — show full-screen spinner
            VStack(spacing: 12) {
                ProgressView("Generating summary…").padding()
                Text("This may take a minute depending on your model.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // No summary, not generating
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("No Summary Yet")
                    .font(AppTheme.Fonts.listTitle)
                Text("Generate AI meeting notes and action items.")
                    .foregroundStyle(.secondary)
                    .font(AppTheme.Fonts.body)
                Button("Generate Summary") {
                    onGenerate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Task Row with Assignee Dropdown

private struct SummaryTaskRowView: View {
    let task: MeetingTask
    let meetingPeople: [Person]
    let isDimmed: Bool
    let onToggle: (MeetingTask) -> Void
    let onUpdateOwner: (MeetingTask, String?) -> Void

    private var isDone: Bool { task.status.lowercased() == "done" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                onToggle(task)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? AppTheme.Colors.accentGreen : AppTheme.Colors.tertiaryText)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.description)
                    .font(AppTheme.Fonts.body)
                    .foregroundStyle(isDone ? AppTheme.Colors.tertiaryText : AppTheme.Colors.primaryText)
                    .strikethrough(isDone, color: AppTheme.Colors.tertiaryText)

                Menu {
                    if task.ownerPersonId != nil || (task.rawOwnerText ?? "").isEmpty == false {
                        Button(role: .destructive) {
                            onUpdateOwner(task, nil)
                        } label: {
                            Label("Unassign", systemImage: "person.slash")
                        }
                        Divider()
                    }
                    ForEach(meetingPeople) { person in
                        Button {
                            onUpdateOwner(task, person.id)
                        } label: {
                            if person.id == task.ownerPersonId {
                                Label(person.displayName, systemImage: "checkmark")
                            } else {
                                Text(person.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(assigneeColor)
                        Text(assigneeLabel)
                            .font(AppTheme.Fonts.caption)
                            .foregroundStyle(assigneeColor)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.tertiaryText)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.hoverFill)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(isDimmed ? 0.4 : 1)
        .padding(.vertical, 4)
    }

    private var assigneeLabel: String {
        if let name = task.rawOwnerText, !name.isEmpty {
            return name
        }
        return "Unassigned"
    }

    private var assigneeColor: Color {
        (task.ownerPersonId != nil || (task.rawOwnerText ?? "").isEmpty == false)
            ? AppTheme.Colors.brandPrimary : AppTheme.Colors.tertiaryText
    }
}
