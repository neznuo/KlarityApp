import SwiftUI

// MARK: - PeopleView

struct PeopleView: View {
    @StateObject private var vm = PeopleViewModel()
    @State private var selectedPersonId: String?
    @State private var showCreateSheet = false
    @State private var newName = ""
    @State private var searchText = ""

    var filteredPeople: [Person] {
        guard !searchText.isEmpty else { return vm.people }
        return vm.people.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.Colors.tertiaryText).font(.system(size: 12))
                    TextField("Search contacts…", text: $searchText)
                        .textFieldStyle(.plain).font(AppTheme.Fonts.body)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(AppTheme.Colors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                    .stroke(AppTheme.Colors.border, lineWidth: 0.5))
                .padding(.horizontal, 12).padding(.vertical, 10)

                Divider().opacity(0.4)

                if vm.people.isEmpty && !vm.isLoading {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "person.2").font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("No contacts yet").font(AppTheme.Fonts.body).foregroundStyle(.secondary)
                        Text("Assign speakers in a meeting\nto create contacts automatically.")
                            .font(AppTheme.Fonts.caption).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                } else {
                    List(filteredPeople, selection: $selectedPersonId) { person in
                        PersonRowView(person: person)
                            .tag(person.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await vm.delete(person) }
                                } label: { Label("Delete Contact", systemImage: "trash") }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .background(AppTheme.Colors.background)
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreateSheet = true } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .help("Add a contact manually")
                }
            }

        } detail: {
            if let id = selectedPersonId,
               let person = vm.people.first(where: { $0.id == id }) {
                PersonDetailView(
                    person: person,
                    onRename: { name in Task { await vm.rename(person, to: name) } },
                    onRecomputeEmbedding: { Task { await vm.recomputeEmbedding(person) } }
                )
            } else {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(AppTheme.Colors.brandLight).frame(width: 72, height: 72)
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 26)).foregroundStyle(AppTheme.Colors.brandPrimary)
                    }
                    Text("Select a contact")
                        .font(AppTheme.Fonts.title).foregroundStyle(AppTheme.Colors.primaryText)
                    Text("View their meetings and voice recognition status.")
                        .font(AppTheme.Fonts.body).foregroundStyle(AppTheme.Colors.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.Colors.background)
            }
        }
        .sheet(isPresented: $showCreateSheet) { createPersonSheet }
        .task { await vm.load() }
        .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
    }

    private var createPersonSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Contact").font(AppTheme.Fonts.title).foregroundStyle(AppTheme.Colors.primaryText)
                Spacer()
                Button { showCreateSheet = false; newName = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.secondaryText).padding(6)
                        .background(AppTheme.Colors.hoverFill).clipShape(Circle())
                }.buttonStyle(.plain)
            }.padding(20)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Display Name")
                    .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.secondaryText)
                    .textCase(.uppercase).kerning(0.3)
                TextField("e.g. Alice Smith", text: $newName)
                    .textFieldStyle(.plain).font(AppTheme.Fonts.body)
                    .padding(10).background(AppTheme.Colors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                        .stroke(AppTheme.Colors.border, lineWidth: 0.5))
                    .onSubmit { createPerson() }
            }.padding(20)

            Divider().opacity(0.4)

            HStack {
                Button("Cancel") { showCreateSheet = false; newName = "" }
                    .buttonStyle(.plain).font(AppTheme.Fonts.body).foregroundStyle(AppTheme.Colors.secondaryText)
                Spacer()
                Button("Create Contact") { createPerson() }
                    .buttonStyle(.plain).font(AppTheme.Fonts.listTitle).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                ? AppTheme.Colors.brandPrimary.opacity(0.4) : AppTheme.Colors.brandPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius))
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(20)
        }
        .frame(width: 380).background(AppTheme.Colors.background)
    }

    private func createPerson() {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            _ = try? await APIClient.shared.createPerson(displayName: newName)
            newName = ""; showCreateSheet = false; await vm.load()
        }
    }
}

// MARK: - Person Sidebar Row

struct PersonRowView: View {
    let person: Person
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(avatarColor.opacity(0.15)).frame(width: 36, height: 36)
                Text(initials).font(.system(size: 13, weight: .semibold)).foregroundStyle(avatarColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName)
                    .font(AppTheme.Fonts.listTitle).foregroundStyle(AppTheme.Colors.primaryText)
                HStack(spacing: 4) {
                    Text("\(person.meetingCount) meeting\(person.meetingCount == 1 ? "" : "s")")
                        .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.secondaryText)
                    if person.hasVoiceEmbedding {
                        Circle().fill(AppTheme.Colors.accentGreen).frame(width: 5, height: 5)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isHovered ? AppTheme.Colors.hoverFill : Color.clear))
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }

    private var initials: String {
        let parts = person.displayName.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(person.displayName.prefix(2)).uppercased()
    }
    private var avatarColor: Color {
        let colors: [Color] = [.indigo, .teal,
            Color(red: 0.85, green: 0.35, blue: 0.25), Color(red: 0.25, green: 0.65, blue: 0.55),
            .purple, Color(red: 0.70, green: 0.45, blue: 0.10)]
        return colors[abs(person.displayName.hashValue) % colors.count]
    }
}

// MARK: - Person Detail

struct PersonDetailView: View {
    let person: Person
    var onRename: (String) -> Void
    var onRecomputeEmbedding: () -> Void

    @StateObject private var meetingsVM = PersonMeetingsViewModel()
    @State private var editName = ""
    @State private var isEditing = false
    @State private var isRebuilding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Header
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(avatarColor.opacity(0.15)).frame(width: 60, height: 60)
                        Text(initials).font(.system(size: 22, weight: .bold)).foregroundStyle(avatarColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if isEditing {
                            HStack(spacing: 8) {
                                TextField("Name", text: $editName)
                                    .textFieldStyle(.plain).font(AppTheme.Fonts.title)
                                    .padding(6).background(AppTheme.Colors.inputBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onSubmit { saveRename() }
                                Button("Save") { saveRename() }
                                    .buttonStyle(.plain).font(AppTheme.Fonts.caption).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(AppTheme.Colors.brandPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Button("Cancel") { isEditing = false }
                                    .buttonStyle(.plain).font(AppTheme.Fonts.caption)
                                    .foregroundStyle(AppTheme.Colors.secondaryText)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Text(person.displayName)
                                    .font(AppTheme.Fonts.title).foregroundStyle(AppTheme.Colors.primaryText)
                                Button { editName = person.displayName; isEditing = true } label: {
                                    Image(systemName: "pencil").font(.system(size: 11))
                                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                                }.buttonStyle(.plain)
                            }
                        }
                        if let seen = person.lastSeenAt {
                            Text("Last seen \(seen.formatted(date: .abbreviated, time: .omitted))")
                                .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.secondaryText)
                        }
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("\(person.meetingCount)")
                            .font(.system(size: 26, weight: .bold)).foregroundStyle(AppTheme.Colors.primaryText)
                        Text("meeting\(person.meetingCount == 1 ? "" : "s")")
                            .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.secondaryText)
                    }
                }
                .padding(24)

                Divider().opacity(0.4)

                // Voice recognition card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Voice Recognition")
                        .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.tertiaryText)
                        .textCase(.uppercase).kerning(0.4)

                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(person.hasVoiceEmbedding
                                      ? AppTheme.Colors.accentGreen.opacity(0.12)
                                      : AppTheme.Colors.accentOrange.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: person.hasVoiceEmbedding
                                  ? "waveform.badge.checkmark" : "waveform.badge.exclamationmark")
                                .font(.system(size: 18))
                                .foregroundStyle(person.hasVoiceEmbedding
                                                 ? AppTheme.Colors.accentGreen : AppTheme.Colors.accentOrange)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.hasVoiceEmbedding ? "Voice model active" : "No voice model yet")
                                .font(AppTheme.Fonts.listTitle).foregroundStyle(AppTheme.Colors.primaryText)
                            Text(person.hasVoiceEmbedding
                                 ? "Will be auto-recognised in future meetings."
                                 : "Assign this person to a speaker cluster to capture their voice.")
                                .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if person.meetingCount > 0 {
                            Button {
                                isRebuilding = true
                                onRecomputeEmbedding()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { isRebuilding = false }
                            } label: {
                                HStack(spacing: 5) {
                                    if isRebuilding { ProgressView().scaleEffect(0.6) }
                                    else { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                                    Text(person.hasVoiceEmbedding ? "Rebuild" : "Build Now")
                                        .font(AppTheme.Fonts.caption)
                                }
                                .foregroundStyle(AppTheme.Colors.brandPrimary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(AppTheme.Colors.brandLight)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).disabled(isRebuilding)
                        }
                    }
                }
                .padding(24)

                Divider().opacity(0.4)

                // Meetings list
                VStack(alignment: .leading, spacing: 10) {
                    Text("Meetings")
                        .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.tertiaryText)
                        .textCase(.uppercase).kerning(0.4)

                    if meetingsVM.isLoading {
                        HStack { Spacer(); ProgressView().scaleEffect(0.8); Spacer() }.padding(.vertical, 12)
                    } else if meetingsVM.meetings.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar.badge.minus").foregroundStyle(AppTheme.Colors.tertiaryText)
                            Text("Not identified in any meeting yet.")
                                .font(AppTheme.Fonts.body).foregroundStyle(AppTheme.Colors.secondaryText)
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(meetingsVM.meetings) { meeting in
                            PersonMeetingRow(meeting: meeting)
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(AppTheme.Colors.background)
        .navigationTitle(person.displayName)
        .task { await meetingsVM.load(personId: person.id) }
        .onChange(of: person.id) { _, newId in Task { await meetingsVM.load(personId: newId) } }
    }

    private func saveRename() {
        let name = editName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onRename(name); isEditing = false
    }
    private var initials: String {
        let parts = person.displayName.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(person.displayName.prefix(2)).uppercased()
    }
    private var avatarColor: Color {
        let colors: [Color] = [.indigo, .teal,
            Color(red: 0.85, green: 0.35, blue: 0.25), Color(red: 0.25, green: 0.65, blue: 0.55),
            .purple, Color(red: 0.70, green: 0.45, blue: 0.10)]
        return colors[abs(person.displayName.hashValue) % colors.count]
    }
}

// MARK: - Person Meeting Row

struct PersonMeetingRow: View {
    let meeting: Meeting
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(AppTheme.Colors.brandLight).frame(width: 30, height: 30)
                Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(AppTheme.Colors.brandPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(AppTheme.Fonts.listTitle).foregroundStyle(AppTheme.Colors.primaryText).lineLimit(1)
                HStack(spacing: 5) {
                    Text(meeting.createdAt.formatted(date: .abbreviated, time: .omitted))
                    if let dur = meeting.durationSeconds, dur > 0 {
                        Text("·"); Text(dur >= 3600
                                        ? "\(Int(dur)/3600)h \((Int(dur)%3600)/60)m"
                                        : "\((Int(dur)%3600)/60)m")
                    }
                }
                .font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.secondaryText)
            }
            Spacer()
            if meeting.status == .complete {
                Text("Complete").font(AppTheme.Fonts.caption).foregroundStyle(AppTheme.Colors.accentGreen)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(AppTheme.Colors.accentGreen.opacity(0.1)).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? AppTheme.Colors.hoverFill : Color.clear))
        .onHover { isHovered = $0 }
    }
}

// MARK: - PersonMeetingsViewModel

@MainActor
final class PersonMeetingsViewModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var isLoading = false

    func load(personId: String) async {
        isLoading = true
        defer { isLoading = false }
        meetings = (try? await APIClient.shared.fetchPersonMeetings(personId: personId)) ?? []
    }
}
