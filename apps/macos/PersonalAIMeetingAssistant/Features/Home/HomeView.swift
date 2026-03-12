import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @State private var showingRecording = false
    @State private var selectedMeetingId: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topActionAndFilterBar
                
                Divider().foregroundStyle(AppTheme.Colors.border)

                if vm.isLoading {
                    ProgressView().padding().frame(maxHeight: .infinity)
                } else if vm.filteredMeetings.isEmpty {
                    emptyState
                } else {
                    meetingList
                }
            }
            .navigationTitle("Meetings")
            // Hide the default navigation bar so our custom top bar sits flush
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    EmptyView()
                }
            }
            .background(AppTheme.Colors.background)
            .sheet(isPresented: $showingRecording) {
                RecordingView { meeting in
                    vm.insertMeeting(meeting)
                    selectedMeetingId = meeting.id
                    showingRecording = false
                    Task { await vm.load() }
                }
            }
            .navigationDestination(item: $selectedMeetingId) { id in
                MeetingDetailView(meetingId: id)
            }
        }
        .task { await vm.load() }
    }
    
    // MARK: - Custom Top Navigation
    
    private var topActionAndFilterBar: some View {
        VStack(spacing: AppTheme.Metrics.paddingSmall) {
            // Action Bar
            HStack(spacing: 12) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.Colors.secondaryText)
                    TextField("Search for titles, notes, and participants", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .font(AppTheme.Fonts.listTitle)
                    
                    Text("⌘ + K")
                        .font(AppTheme.Fonts.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.windowBackgroundColor))
                        .cornerRadius(4)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                )
                
                Spacer()
                
                // Top Right Buttons
                HStack(spacing: 8) {
                    Button(action: { showingRecording = true }) {
                        HStack {
                            Image(systemName: "record.circle")
                            Text("Record")
                        }
                        .font(AppTheme.Fonts.listTitle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(AppTheme.Metrics.cornerRadius)
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius).stroke(AppTheme.Colors.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, AppTheme.Metrics.paddingStandard)
            
            // Filter Pill Row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterPill(icon: "calendar", title: "Date")
                    filterPill(icon: "a.magnify", title: "Contains")
                    filterPill(icon: "person.crop.circle", title: "Owner")
                    filterPill(icon: "building.2", title: "Company")
                    filterPill(icon: "folder", title: "Type")
                    filterPill(icon: "tag", title: "Tags")
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Text("Sort by date")
                            .font(AppTheme.Fonts.listTitle)
                        Image(systemName: "chevron.down")
                            .font(AppTheme.Fonts.caption)
                    }
                    .padding(.leading, 12)
                }
                .padding(.horizontal, AppTheme.Metrics.paddingStandard)
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 12)
    }
    
    private func topActionButton(icon: String, title: String, color: Color) -> some View {
        Button(action: {}) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(AppTheme.Fonts.listTitle)
            .foregroundColor(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(AppTheme.Metrics.cornerRadius)
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius).stroke(AppTheme.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    
    private func filterPill(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(title)
        }
        .font(AppTheme.Fonts.listTitle)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.Colors.border, lineWidth: 1))
    }

    // MARK: - Data Table
    
    private var meetingList: some View {
        List(selection: $selectedMeetingId) {
            ForEach(vm.filteredMeetings) { meeting in
                NavigationLink(value: meeting.id) {
                    MeetingRowView(meeting: meeting)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.visible)
                .listRowBackground(Color.clear)
                // Remove the default NavigationLink chevron styling for a cleaner table look
                .buttonStyle(.plain) 
                .contextMenu {
                    if meeting.status == .failed {
                        Button { Task { await vm.retryMeeting(meeting) } } label: {
                            Label("Retry Transcription", systemImage: "arrow.clockwise")
                        }
                    }
                    Button(role: .destructive) { Task { await vm.deleteMeeting(meeting) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await vm.load() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No Meetings Yet")
                .font(.title2.bold())
            Text("Click \"Record\" to start capturing your first meeting.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
}

// MARK: - Dense Row Layout
struct MeetingRowView: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox & Star
            Image(systemName: "square")
                .foregroundStyle(AppTheme.Colors.secondaryText)
            Image(systemName: "star")
                .foregroundStyle(AppTheme.Colors.secondaryText)
            
            // Audio Icon
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .frame(width: 20)
            
            // Title & Duration
            HStack(spacing: 4) {
                Text(meeting.title)
                    .font(AppTheme.Fonts.listTitle)
                    .foregroundColor(AppTheme.Colors.primaryText)
                    .lineLimit(1)
                
                Text(formatDuration(Int(meeting.durationSeconds ?? 0)))
                    .font(AppTheme.Fonts.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
            
            Spacer(minLength: 24)
            
            // Avatar Stack (Simulated for Krisp look)
            HStack(spacing: -8) {
                Circle().fill(Color.gray.opacity(0.3)).frame(width: 24, height: 24)
                Circle().fill(Color.blue.opacity(0.5)).frame(width: 24, height: 24)
                Text("+2")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
            }
            
            Spacer().frame(width: 48)
            
            // End Icons
            Image(systemName: "lock")
                .foregroundStyle(AppTheme.Colors.secondaryText)
            
            Text(" R ")
                .font(AppTheme.Fonts.smallMono)
                .padding(2)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
                .foregroundColor(AppTheme.Colors.secondaryText)
            
            // Status badge
            statusBadge

            // Date
            Text(formatDate(meeting.createdAt))
                .font(AppTheme.Fonts.listTitle)
                .foregroundColor(AppTheme.Colors.secondaryText)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle()) // Makes the whole row clickable
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.status {
        case .preprocessing, .transcribing, .matchingSpeakers:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text(meeting.status.displayName)
                    .font(AppTheme.Fonts.smallMono)
                    .foregroundColor(AppTheme.Colors.brandPrimary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.Colors.brandPrimary.opacity(0.08))
            .cornerRadius(4)
        case .summarizing:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text("Summarizing")
                    .font(AppTheme.Fonts.smallMono)
                    .foregroundColor(AppTheme.Colors.accentOrange)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.Colors.accentOrange.opacity(0.08))
            .cornerRadius(4)
        case .failed:
            Text("Failed")
                .font(AppTheme.Fonts.smallMono)
                .foregroundColor(AppTheme.Colors.accentRed)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.Colors.accentRed.opacity(0.08))
                .cornerRadius(4)
        case .complete:
            Text("Done")
                .font(AppTheme.Fonts.smallMono)
                .foregroundColor(AppTheme.Colors.accentGreen)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.Colors.accentGreen.opacity(0.08))
                .cornerRadius(4)
        default:
            EmptyView()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds == 0 { return "0m" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d" // e.g., "Jan 6"
        return formatter.string(from: date)
    }
}
