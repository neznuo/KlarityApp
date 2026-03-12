import SwiftUI
import AVKit

/// The main meeting detail page: tabbed Transcript / Summary with persistent audio player.
struct MeetingDetailView: View {
    let meetingId: String

    @StateObject private var vm = MeetingDetailViewModel()
    @State private var selectedTab: Tab = .transcript
    @State private var playerSeekTarget: Double? = nil

    enum Tab { case transcript, summary }

    var body: some View {
        VStack(spacing: 0) {
            // ── Custom Top Bar ────────────────────────────────────────────────
            customTopBar
            
            Divider().foregroundStyle(AppTheme.Colors.border)
            
            // ── Tab Navigation ────────────────────────────────────────────────
            HStack(spacing: 24) {
                tabButton(title: "Notes", tab: .summary)
                tabButton(title: "Recording & Transcript", tab: .transcript)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Metrics.paddingStandard)
            .padding(.top, 12)
            .background(AppTheme.Colors.background)
            
            Divider().foregroundStyle(AppTheme.Colors.border)

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
                        onRetry: {
                            Task { await vm.retryProcessing() }
                        }
                    )
                case .summary:
                    SummaryView(
                        summary: vm.summary,
                        tasks: vm.tasks,
                        isSummarizing: vm.isSummarizing,
                        onGenerate: {
                            Task { await vm.generateSummary() }
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
            .background(Color(NSColor.controlBackgroundColor))
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
        HStack {
            // Breadcrumb
            HStack(spacing: 8) {
                Text(vm.meeting?.createdAt.formatted(date: .omitted, time: .shortened) ?? "Time")
                    .foregroundColor(AppTheme.Colors.secondaryText)
                Text("-")
                    .foregroundColor(AppTheme.Colors.border)
                Text(vm.meeting?.title ?? "Loading...")
                    .font(AppTheme.Fonts.listTitle)
                    .foregroundColor(AppTheme.Colors.primaryText)
                
                if vm.meeting?.status.isProcessing == true {
                    ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                }
            }
            .font(AppTheme.Fonts.listTitle)
            
            Spacer()
            
            // Action Buttons
            HStack(spacing: 12) {
                actionButton(icon: "sparkles", title: "Summarize", color: AppTheme.Colors.brandPrimary) {
                    if selectedTab != .summary { selectedTab = .summary }
                    Task { await vm.generateSummary() }
                }
                
                actionButton(icon: "square.and.arrow.up", title: "Share", color: AppTheme.Colors.secondaryText) {}
                actionButton(icon: "clock.arrow.circlepath", title: "History", color: AppTheme.Colors.secondaryText) {}
                
                Button(action: {}) {
                    Image(systemName: "ellipsis")
                        .foregroundColor(AppTheme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppTheme.Metrics.paddingStandard)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.background)
    }
    
    private func actionButton(icon: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(AppTheme.Fonts.caption)
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(AppTheme.Metrics.cornerRadius)
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius).stroke(AppTheme.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    
    private func tabButton(title: String, tab: Tab) -> some View {
        Button(action: { selectedTab = tab }) {
            VStack(spacing: 8) {
                Text(title)
                    .font(AppTheme.Fonts.listTitle)
                    .foregroundColor(selectedTab == tab ? AppTheme.Colors.primaryText : AppTheme.Colors.secondaryText)
                
                // Underline indicator
                Rectangle()
                    .fill(selectedTab == tab ? AppTheme.Colors.primaryText : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Summary Sub-View

struct SummaryView: View {
    let summary: MeetingSummary?
    let tasks: [MeetingTask]
    let isSummarizing: Bool
    let onGenerate: () -> Void

    var body: some View {
        if isSummarizing {
            VStack {
                ProgressView("Generating summary…").padding()
                Text("This may take a minute depending on your model.")
                    .foregroundStyle(.secondary).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let md = summary.summaryMarkdown {
                        Text(.init(md))
                            .font(AppTheme.Fonts.body)
                            .lineSpacing(4)
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
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: task.status.lowercased() == "completed" ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.status.lowercased() == "completed" ? .green : .secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.description).font(AppTheme.Fonts.body)
                                    if let w = task.rawOwnerText, !w.isEmpty {
                                        Text("Assignee: \(w)")
                                            .font(AppTheme.Fonts.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(24)
            }
        } else {
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
