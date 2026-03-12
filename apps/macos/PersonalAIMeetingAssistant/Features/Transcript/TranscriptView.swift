import SwiftUI

/// Transcript tab view — scrollable list of segments with inline chat-style speaker labels.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let speakers: [SpeakerCluster]
    let people: [Person]
    var status: MeetingStatus?
    var onSeek: (Int) -> Void
    var onAssign: (SpeakerCluster, Person) -> Void
    var onCreateAndAssign: (SpeakerCluster, String) -> Void
    var onRetry: (() -> Void)?

    @State private var newPersonInputFor: SpeakerCluster? = nil
    @State private var newPersonName: String = ""

    var body: some View {
        Group {
            if segments.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    if status == .failed {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                        Text("Transcription Failed")
                            .font(.headline)
                        Text("An error occurred during processing.")
                            .foregroundStyle(.secondary)
                        if let onRetry {
                            Button("Retry Transcription") {
                                onRetry()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if status?.isProcessing == true || status == .recording {
                        ProgressView()
                        Text("Processing...")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Transcript not yet available.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(segments) { seg in
                            TranscriptRowView(
                                segment: seg,
                                cluster: speakers.first(where: { $0.id == seg.clusterId }),
                                people: people,
                                onSeek: { onSeek(seg.startMs) },
                                onAssign: { person in
                                    if let c = speakers.first(where: { $0.id == seg.clusterId }) {
                                        onAssign(c, person)
                                    }
                                },
                                onCreateNew: {
                                    if let c = speakers.first(where: { $0.id == seg.clusterId }) {
                                        newPersonInputFor = c
                                    }
                                }
                            )
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: 800, alignment: .leading) // Constrain width for readability
                }
            }
        }
        .background(AppTheme.Colors.background)
        .sheet(item: $newPersonInputFor) { cluster in
            VStack(spacing: 16) {
                Text("Create New Person")
                    .font(.headline)
                Text("Assign a name to \(cluster.tempLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Name (e.g., Alice)", text: $newPersonName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit { submitNewPerson(for: cluster) }

                HStack {
                    Button("Cancel") { newPersonInputFor = nil }
                    Button("Create & Assign") { submitNewPerson(for: cluster) }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }

    private func submitNewPerson(for cluster: SpeakerCluster) {
        let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onCreateAndAssign(cluster, name)
        newPersonName = ""
        newPersonInputFor = nil
    }
}

// MARK: - Row Components

struct TranscriptRowView: View {
    let segment: TranscriptSegment
    let cluster: SpeakerCluster?
    let people: [Person]
    var onSeek: () -> Void
    var onAssign: (Person) -> Void
    var onCreateNew: () -> Void

    @State private var isHovered = false

    var speakerName: String {
        if let pid = cluster?.assignedPersonId,
           let match = people.first(where: { $0.id == pid }) {
            return match.displayName
        }
        // Fallback to "Speaker 1", "Speaker 2"
        return cluster?.tempLabel ?? "Speaker Unknown"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            
            // Avatar Column
            Circle()
                .fill(avatarColor(for: speakerName))
                .frame(width: 36, height: 36)
                .overlay(Text(initials(for: speakerName)).font(AppTheme.Fonts.listTitle).foregroundColor(.white))
            
            // Content Column
            VStack(alignment: .leading, spacing: 4) {
                // Name & Timecode
                HStack(spacing: 8) {
                    Text(speakerName)
                        .font(AppTheme.Fonts.listTitle)
                        .foregroundColor(AppTheme.Colors.primaryText)
                    
                    Button(action: onSeek) {
                        Text(formatTimestamp(segment.startMs))
                            .font(AppTheme.Fonts.smallMono)
                            .foregroundColor(AppTheme.Colors.brandPrimary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(AppTheme.Colors.brandPrimary.opacity(0.1))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Jump to this timestamp")
                    
                    if isHovered {
                        Menu {
                            Section("Assign speaker to…") {
                                ForEach(people) { person in
                                    Button(person.displayName) { onAssign(person) }
                                }
                                Divider()
                                Button("Create new person…") { onCreateNew() }
                            }
                        } label: {
                            Image(systemName: "pencil")
                                .font(AppTheme.Fonts.caption)
                                .foregroundColor(AppTheme.Colors.secondaryText)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 16) // Prevent layout jumping when hovered
                    }
                }
                
                // Spoken Text
                Text(segment.text)
                    .font(AppTheme.Fonts.body)
                    .foregroundColor(AppTheme.Colors.primaryText.opacity(0.9))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true) // Prevents truncation
                    .textSelection(.enabled) // Enable copy/pasting text
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? AppTheme.Colors.border.opacity(0.3) : Color.clear)
        .cornerRadius(AppTheme.Metrics.cornerRadius)
        .onHover { isHovered = $0 }
    }

    private func formatTimestamp(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func initials(for name: String) -> String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else if let first = components.first {
            return String(first.prefix(1)).uppercased()
        }
        return "?"
    }
    
    // Deterministic color based on speaker name
    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .indigo, .pink]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }
}
