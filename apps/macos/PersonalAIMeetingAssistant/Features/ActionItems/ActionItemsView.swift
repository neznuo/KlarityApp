import SwiftUI

struct ActionItemsView: View {
    @StateObject private var vm = ActionItemsViewModel()

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────────
            HStack {
                Text("Action Items")
                    .font(AppTheme.Fonts.title)
                    .foregroundStyle(AppTheme.Colors.primaryText)

                Spacer()

                // Status filter
                Picker("", selection: $vm.statusFilter) {
                    ForEach(StatusFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()

                // Assignee filter
                Picker("", selection: $vm.filter) {
                    ForEach(TaskFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // ── "My Name" hint bar (only when Assigned to Me is active) ─────────
            if vm.filter == .mine {
                HStack(spacing: 8) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.Colors.brandPrimary)
                    Text("Your name:")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                    TextField("e.g. Rahul", text: $vm.myName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(maxWidth: 180)
                    if vm.myName.isEmpty {
                        Text("Set your name to filter tasks assigned to you.")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.Colors.tertiaryText)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(AppTheme.Colors.hoverFill)

                Divider()
            }

            Divider()

            // ── Content ─────────────────────────────────────────────────────────
            if vm.isLoading {
                Spacer()
                ProgressView("Loading action items…")
                Spacer()

            } else if let error = vm.errorMessage {
                Spacer()
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                .foregroundStyle(.red)
                Spacer()

            } else if vm.tasksByMeeting.isEmpty {
                Spacer()
                ContentUnavailableView(
                    vm.filter == .mine ? "No tasks assigned to you" : "No action items",
                    systemImage: "checkmark.circle",
                    description: Text(vm.filter == .mine ? "Switch to \"All Tasks\" to see every item." : "Action items from meetings will appear here.")
                )
                Spacer()

            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                        ForEach(vm.tasksByMeeting, id: \.meetingId) { group in
                            MeetingTaskSection(
                                title: group.title,
                                tasks: group.tasks,
                                onToggle: { task in Task { await vm.toggleTaskStatus(task) } },
                                onDelete: { task in Task { await vm.deleteTask(task) } },
                                onUpdateOwner: { task, owner in Task { await vm.updateTaskOwner(task, newOwner: owner) } }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }
}

// MARK: - Meeting Section

private struct MeetingTaskSection: View {
    let title: String
    let tasks: [MeetingTask]
    let onToggle: (MeetingTask) -> Void
    let onDelete: (MeetingTask) -> Void
    let onUpdateOwner: (MeetingTask, String) -> Void

    @State private var isExpanded = true

    var completedCount: Int { tasks.filter { $0.status.lowercased() == "done" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Section header — tappable to collapse/expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .frame(width: 14)

                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.brandPrimary)

                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.primaryText)
                        .lineLimit(1)

                    Spacer()

                    // e.g. "2 / 5"
                    Text("\(completedCount) / \(tasks.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                        .monospacedDigit()

                    // Mini progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppTheme.Colors.hoverFill)
                            if tasks.count > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(AppTheme.Colors.accentGreen)
                                    .frame(width: geo.size.width * CGFloat(completedCount) / CGFloat(tasks.count))
                            }
                        }
                    }
                    .frame(width: 48, height: 5)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppTheme.Colors.hoverFill)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            // Task rows
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        TaskRowView(task: task, onToggle: onToggle, onDelete: onDelete, onUpdateOwner: onUpdateOwner)

                        if task.id != tasks.last?.id {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(AppTheme.Colors.cardSurface)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.Colors.subtleBorder, lineWidth: 0.5)
                )
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Task Row

private struct TaskRowView: View {
    let task: MeetingTask
    let onToggle: (MeetingTask) -> Void
    let onDelete: (MeetingTask) -> Void
    let onUpdateOwner: (MeetingTask, String) -> Void

    @State private var isHovered = false
    @State private var isEditingOwner = false
    @State private var ownerDraft: String = ""

    private var isDone: Bool { task.status.lowercased() == "done" }
    private var displayOwner: String { task.rawOwnerText ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {

            // Checkbox
            Button { onToggle(task) } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isDone ? AppTheme.Colors.accentGreen : AppTheme.Colors.tertiaryText)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            // Description + meta
            VStack(alignment: .leading, spacing: 4) {
                Text(task.description)
                    .font(.system(size: 13))
                    .foregroundStyle(isDone ? AppTheme.Colors.tertiaryText : AppTheme.Colors.primaryText)
                    .strikethrough(isDone, color: AppTheme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    // ── Assignee (editable) ────────────────────────────────
                    if isEditingOwner {
                        HStack(spacing: 4) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AppTheme.Colors.brandPrimary)
                            TextField("Assignee", text: $ownerDraft, onCommit: commitOwner)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.Colors.primaryText)
                                .frame(minWidth: 80, maxWidth: 160)
                                .onExitCommand { cancelOwnerEdit() }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppTheme.Colors.hoverFill)
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.Colors.brandPrimary.opacity(0.5), lineWidth: 1))

                        Button(action: commitOwner) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.accentGreen)
                        }
                        .buttonStyle(.plain)

                        Button(action: cancelOwnerEdit) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppTheme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)

                    } else {
                        // Chip — click to edit
                        Button(action: beginOwnerEdit) {
                            HStack(spacing: 4) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(displayOwner.isEmpty ? AppTheme.Colors.tertiaryText : AppTheme.Colors.brandPrimary)
                                Text(displayOwner.isEmpty ? "Unassigned" : displayOwner)
                                    .font(.system(size: 11))
                                    .foregroundStyle(displayOwner.isEmpty ? AppTheme.Colors.tertiaryText : AppTheme.Colors.brandPrimary)
                                Image(systemName: "pencil")
                                    .font(.system(size: 8))
                                    .foregroundStyle(AppTheme.Colors.tertiaryText)
                                    .opacity(isHovered ? 1 : 0)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppTheme.Colors.hoverFill.opacity(isHovered ? 1 : 0))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Click to change assignee")
                    }

                    // Due date chip (read-only)
                    if let due = task.dueDate, !due.isEmpty {
                        Label(due, systemImage: "calendar.badge.clock")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    }
                }
            }

            Spacer()

            // Delete button — visible on hover
            if isHovered && !isEditingOwner {
                Button {
                    withAnimation { onDelete(task) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.accentRed.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Delete task")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? AppTheme.Colors.hoverFill : Color.clear)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func beginOwnerEdit() {
        ownerDraft = displayOwner
        withAnimation { isEditingOwner = true }
    }

    private func commitOwner() {
        let trimmed = ownerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onUpdateOwner(task, trimmed)
        withAnimation { isEditingOwner = false }
    }

    private func cancelOwnerEdit() {
        ownerDraft = displayOwner
        withAnimation { isEditingOwner = false }
    }
}

#Preview {
    ActionItemsView()
        .frame(width: 640, height: 500)
}
