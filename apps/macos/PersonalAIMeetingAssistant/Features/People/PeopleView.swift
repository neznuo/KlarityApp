import SwiftUI

struct PeopleView: View {
    @StateObject private var vm = PeopleViewModel()
    @State private var selection: String?
    @State private var showCreateSheet = false
    @State private var newName = ""

    var body: some View {
        NavigationSplitView {
            List(vm.people, selection: $selection) { person in
                PersonRowView(person: person)
                    .tag(person.id)
                    .contextMenu {
                        Button("Rename…") {
                            selection = person.id
                        }
                        Button(role: .destructive) {
                            Task { await vm.delete(person) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .navigationTitle("Known People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreateSheet = true } label: {
                        Label("Add Person", systemImage: "person.badge.plus")
                    }
                }
            }
        } detail: {
            if let id = selection, let person = vm.people.first(where: { $0.id == id }) {
                PersonDetailView(person: person, onRename: { newName in
                    Task { await vm.rename(person, to: newName) }
                })
            } else {
                VStack {
                    Image(systemName: "person.2").font(.system(size: 52)).foregroundStyle(.tertiary)
                    Text("Select a person to view details").foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            VStack(spacing: 16) {
                Text("Add Person").font(.headline)
                TextField("Display Name", text: $newName)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                HStack {
                    Button("Cancel") { showCreateSheet = false; newName = "" }
                    Button("Create") {
                        Task {
                            _ = try? await APIClient.shared.createPerson(displayName: newName)
                            newName = ""
                            showCreateSheet = false
                            await vm.load()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(32)
        }
        .task { await vm.load() }
    }
}

struct PersonRowView: View {
    let person: Person

    var body: some View {
        HStack {
            Image(systemName: "person.circle.fill")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(person.displayName).font(.headline)
                Text("\(person.meetingCount) meeting\(person.meetingCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PersonDetailView: View {
    let person: Person
    var onRename: (String) -> Void

    @State private var editName: String = ""
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("Identity") {
                if isEditing {
                    HStack {
                        TextField("Name", text: $editName).textFieldStyle(.roundedBorder)
                        Button("Save") {
                            onRename(editName); isEditing = false
                        }.buttonStyle(.borderedProminent)
                        Button("Cancel") { isEditing = false }.buttonStyle(.bordered)
                    }
                } else {
                    HStack {
                        Text(person.displayName).font(.title3)
                        Spacer()
                        Button("Rename") { editName = person.displayName; isEditing = true }
                    }
                }
            }
            Section("Stats") {
                LabeledContent("Meetings", value: "\(person.meetingCount)")
                if let seen = person.lastSeenAt {
                    LabeledContent("Last seen", value: seen.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(person.displayName)
        .padding()
    }
}
