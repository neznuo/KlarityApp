import SwiftUI

/// Transcript tab view — speaker strip at top + scrollable segments below.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let speakers: [SpeakerCluster]
    let people: [Person]
    var status: MeetingStatus?
    var onSeek: (Int) -> Void
    var onAssign: (SpeakerCluster, Person) -> Void
    var onCreateAndAssign: (SpeakerCluster, String) -> Void
    var onConfirmSuggestion: (SpeakerCluster) -> Void
    var onDismissSuggestion: (SpeakerCluster) -> Void
    var onRetry: (() -> Void)?

    @State private var newPersonInputFor: SpeakerCluster? = nil
    @State private var newPersonName: String = ""

    /// First segment timestamp per cluster, for seeking.
    private var firstSegmentMsByCluster: [String: Int] {
        var map: [String: Int] = [:]
        for seg in segments {
            if map[seg.clusterId ?? ""] == nil {
                map[seg.clusterId ?? ""] = seg.startMs
            }
        }
        return map
    }

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
                VStack(spacing: 0) {
                    // ── Speaker Strip ──────────────────────────────────────
                    if !speakers.isEmpty {
                        SpeakerStrip(
                            speakers: speakers,
                            people: people,
                            firstSegmentMsByCluster: firstSegmentMsByCluster,
                            onSeek: onSeek,
                            onAssign: onAssign,
                            onCreateAndAssign: onCreateAndAssign,
                            onConfirmSuggestion: onConfirmSuggestion,
                            onDismissSuggestion: onDismissSuggestion
                        )
                        Divider().opacity(0.4)
                    }

                    // ── Transcript Segments ─────────────────────────────────
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
                                    },
                                    onConfirmSuggestion: {
                                        if let c = speakers.first(where: { $0.id == seg.clusterId }) {
                                            onConfirmSuggestion(c)
                                        }
                                    },
                                    onDismissSuggestion: {
                                        if let c = speakers.first(where: { $0.id == seg.clusterId }) {
                                            onDismissSuggestion(c)
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

// MARK: - Speaker Strip

private struct SpeakerStrip: View {
    let speakers: [SpeakerCluster]
    let people: [Person]
    let firstSegmentMsByCluster: [String: Int]
    var onSeek: (Int) -> Void
    var onAssign: (SpeakerCluster, Person) -> Void
    var onCreateAndAssign: (SpeakerCluster, String) -> Void
    var onConfirmSuggestion: (SpeakerCluster) -> Void
    var onDismissSuggestion: (SpeakerCluster) -> Void

    @State private var hoveredClusterId: String?

    /// Deduplicated speakers: merges multiple clusters assigned to the same person
    /// into a single chip. Unmatched and suggested clusters remain separate.
    private var deduplicatedSpeakers: [SpeakerCluster] {
        var seen = Set<String>()  // person IDs we've already emitted a chip for
        var result: [SpeakerCluster] = []

        // First pass: assigned clusters (deduplicate by person)
        for cluster in speakers {
            if let personId = cluster.assignedPersonId {
                guard !seen.contains(personId) else { continue }
                seen.insert(personId)
                result.append(cluster)
            }
        }

        // Second pass: suggested and unmatched clusters (keep separate)
        for cluster in speakers {
            if cluster.assignedPersonId != nil { continue } // already handled
            result.append(cluster)
        }

        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(deduplicatedSpeakers) { cluster in
                    speakerChip(for: cluster)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func speakerChip(for cluster: SpeakerCluster) -> some View {
        let resolvedName = displayName(for: cluster)
        let firstMs = firstSegmentMsByCluster[cluster.id] ?? 0

        HStack(spacing: 6) {
            // Avatar
            ZStack {
                Circle()
                    .fill(avatarColor(for: resolvedName).opacity(0.18))
                    .frame(width: 26, height: 26)
                Text(initials(for: resolvedName))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(avatarColor(for: resolvedName))
            }

            // Name + status
            if let personId = cluster.assignedPersonId,
               let person = people.first(where: { $0.id == personId }) {
                // ── Assigned ──
                Text(person.displayName)
                    .font(AppTheme.Fonts.caption)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.accentGreen)
            } else if let suggestedName = cluster.suggestedPersonName,
                      let confidence = cluster.confidence {
                // ── Suggested ──
                Text("Probably \(suggestedName) (\(Int(confidence * 100))%)")
                    .font(AppTheme.Fonts.caption)
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
                Button {
                    onConfirmSuggestion(cluster)
                } label: {
                    Text("Confirm")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(AppTheme.Colors.brandPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                Button {
                    onDismissSuggestion(cluster)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            } else {
                // ── Unmatched ──
                Text(cluster.tempLabel)
                    .font(AppTheme.Fonts.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                Circle()
                    .fill(AppTheme.Colors.accentOrange)
                    .frame(width: 6, height: 6)

                if hoveredClusterId == cluster.id {
                    Menu {
                        Section("Assign to…") {
                            ForEach(people) { person in
                                Button(person.displayName) { onAssign(cluster, person) }
                            }
                            Divider()
                            Button("Create new person…") {
                                // Can't use sheet from Menu — tap the row instead
                            }
                        }
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredClusterId == cluster.id ? AppTheme.Colors.hoverFill : AppTheme.Colors.cardBackground)
        )
        .onHover { hovering in
            hoveredClusterId = hovering ? cluster.id : nil
        }
        .onTapGesture {
            onSeek(firstMs)
        }
    }

    private func displayName(for cluster: SpeakerCluster) -> String {
        if let pid = cluster.assignedPersonId,
           let person = people.first(where: { $0.id == pid }) {
            return person.displayName
        }
        if let name = cluster.suggestedPersonName {
            return name
        }
        return cluster.tempLabel
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

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            Color.indigo, Color.teal,
            Color(red: 0.85, green: 0.35, blue: 0.25),
            Color(red: 0.25, green: 0.65, blue: 0.55),
            Color.purple,
            Color(red: 0.70, green: 0.45, blue: 0.10),
        ]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
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
    var onConfirmSuggestion: () -> Void
    var onDismissSuggestion: () -> Void

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
        HStack(alignment: .top, spacing: 14) {
            // Avatar
            ZStack {
                Circle()
                    .fill(avatarColor(for: speakerName).opacity(0.18))
                    .frame(width: 34, height: 34)
                Text(initials(for: speakerName))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(avatarColor(for: speakerName))
            }

            // Content
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(speakerName)
                        .font(AppTheme.Fonts.listTitle)
                        .foregroundStyle(AppTheme.Colors.primaryText)

                    // Suggestion badge: "Probably Colin Graham (87%)"
                    if let cluster = cluster,
                       cluster.assignedPersonId == nil,
                       let suggestedName = cluster.suggestedPersonName,
                       let confidence = cluster.confidence {
                        HStack(spacing: 4) {
                            Text("Probably \(suggestedName) (\(Int(confidence * 100))%)")
                                .font(AppTheme.Fonts.caption)
                                .foregroundStyle(AppTheme.Colors.brandPrimary)
                            Button {
                                onConfirmSuggestion()
                            } label: {
                                Text("Confirm")
                                    .font(AppTheme.Fonts.caption)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.Colors.brandPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            Button {
                                onDismissSuggestion()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.Colors.brandLight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    Button(action: onSeek) {
                        Text(formatTimestamp(segment.startMs))
                            .font(AppTheme.Fonts.smallMono)
                            .foregroundStyle(AppTheme.Colors.brandPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AppTheme.Colors.brandSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to this timestamp in the recording")

                    if isHovered {
                        Menu {
                            Section("Assign to…") {
                                ForEach(people) { person in
                                    Button(person.displayName) { onAssign(person) }
                                }
                                Divider()
                                Button("Create new person…") { onCreateNew() }
                            }
                        } label: {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 18)
                    }
                }

                Text(segment.text)
                    .font(AppTheme.Fonts.body)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isHovered
                ? AppTheme.Colors.cardBackground
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
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
    
    // Deterministic color — uses indigo/teal/coral palette for a cohesive feel
    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [
            Color.indigo, Color.teal,
            Color(red: 0.85, green: 0.35, blue: 0.25),  // coral
            Color(red: 0.25, green: 0.65, blue: 0.55),  // emerald
            Color.purple,
            Color(red: 0.70, green: 0.45, blue: 0.10),  // amber
        ]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }
}
