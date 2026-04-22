# Assignee Dropdown in Meeting Notes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an assignee dropdown to each task row in the Meeting Notes tab, populated with people from the meeting, that links tasks to Person records via `owner_person_id`.

**Architecture:** Backend adds `owner_person_id` to `TaskUpdate` schema and the update endpoint resolves it to a Person record, syncing `raw_owner_text` with the person's display name. Frontend passes `people` and `speakers` into `SummaryView`, derives meeting people, and renders a SwiftUI `Menu` for assignee selection. `MeetingDetailViewModel` gets a new `updateTaskOwner` method with optimistic update.

**Tech Stack:** Python/FastAPI (backend), Swift/SwiftUI (frontend), SQLite/SQLAlchemy (DB)

---

### Task 1: Backend — Add `owner_person_id` to TaskUpdate schema

**Files:**
- Modify: `backend/app/schemas/task.py`
- Modify: `backend/app/api/tasks.py`
- Modify: `backend/app/models/task.py` (verify `owner_person_id` column exists)
- Test: `backend/tests/test_tasks.py` (create)

- [ ] **Step 1: Verify the `owner_person_id` column exists on the Task model**

Read `backend/app/models/task.py` and confirm `owner_person_id` is already present. It should be:

```python
owner_person_id: Mapped[Optional[str]] = mapped_column(
    String, ForeignKey("people.id"), nullable=True
)
```

If it's missing, add it.

- [ ] **Step 2: Add `owner_person_id` to `TaskUpdate` schema**

In `backend/app/schemas/task.py`, add the field to `TaskUpdate`:

```python
class TaskUpdate(BaseModel):
    status: Optional[str] = None
    description: Optional[str] = None
    raw_owner_text: Optional[str] = None
    owner_person_id: Optional[str] = None
```

- [ ] **Step 3: Update the `update_task` endpoint to handle `owner_person_id`**

In `backend/app/api/tasks.py`, update the `update_task` function. Add the import for `Person` and handle the new field:

```python
from app.models.person import Person

# Inside update_task, after the existing payload checks:

if payload.owner_person_id is not None:
    if payload.owner_person_id.strip() == "":
        # Empty string = unassign
        task.owner_person_id = None
        task.raw_owner_text = None
    else:
        person = db.get(Person, payload.owner_person_id)
        if not person:
            raise HTTPException(status_code=404, detail="Person not found")
        task.owner_person_id = person.id
        task.raw_owner_text = person.display_name
```

- [ ] **Step 4: Write a test for the new behavior**

Create `backend/tests/test_tasks.py`:

```python
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.db.database import get_db, Base, engine
from app.models.meeting import Meeting
from app.models.task import Task
from app.models.person import Person
from sqlalchemy.orm import Session

client = TestClient(app)


@pytest.fixture(autouse=True)
def setup_db():
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


def _create_meeting(db: Session) -> Meeting:
    m = Meeting(title="Test Meeting")
    db.add(m)
    db.commit()
    db.refresh(m)
    return m


def _create_person(db: Session, name: str = "Alice") -> Person:
    p = Person(display_name=name)
    db.add(p)
    db.commit()
    db.refresh(p)
    return p


def test_update_task_assign_person():
    db = next(get_db())
    meeting = _create_meeting(db)
    person = _create_person(db, "Alice")
    task = Task(meeting_id=meeting.id, description="Do something")
    db.add(task)
    db.commit()
    db.refresh(task)

    resp = client.patch(f"/tasks/{task.id}", json={"owner_person_id": person.id})
    assert resp.status_code == 200
    data = resp.json()
    assert data["owner_person_id"] == person.id
    assert data["raw_owner_text"] == "Alice"


def test_update_task_unassign():
    db = next(get_db())
    meeting = _create_meeting(db)
    person = _create_person(db, "Bob")
    task = Task(
        meeting_id=meeting.id,
        description="Do something",
        owner_person_id=person.id,
        raw_owner_text="Bob",
    )
    db.add(task)
    db.commit()
    db.refresh(task)

    resp = client.patch(f"/tasks/{task.id}", json={"owner_person_id": ""})
    assert resp.status_code == 200
    data = resp.json()
    assert data["owner_person_id"] is None
    assert data["raw_owner_text"] is None


def test_update_task_invalid_person():
    db = next(get_db())
    meeting = _create_meeting(db)
    task = Task(meeting_id=meeting.id, description="Do something")
    db.add(task)
    db.commit()
    db.refresh(task)

    resp = client.patch(f"/tasks/{task.id}", json={"owner_person_id": "nonexistent"})
    assert resp.status_code == 404
```

- [ ] **Step 5: Run the tests**

Run: `cd backend && python -m pytest tests/test_tasks.py -v`
Expected: All 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add backend/app/schemas/task.py backend/app/api/tasks.py backend/tests/test_tasks.py
git commit -m "feat(tasks): add owner_person_id to TaskUpdate schema and endpoint"
```

---

### Task 2: Frontend — Add `ownerPersonId` parameter to `APIClient.updateTask`

**Files:**
- Modify: `apps/macos/PersonalAIMeetingAssistant/Services/APIClient.swift` (line ~204)

- [ ] **Step 1: Update `APIClient.updateTask` to accept `ownerPersonId`**

Change the method signature and body at line 204:

```swift
func updateTask(taskId: String, status: String? = nil, ownerText: String? = nil, ownerPersonId: String? = nil) async throws -> MeetingTask {
    var body: [String: String] = [:]
    if let s = status { body["status"] = s }
    if let o = ownerText { body["raw_owner_text"] = o }
    if let pid = ownerPersonId { body["owner_person_id"] = pid }
    return try await patch("/tasks/\(taskId)", body: body)
}
```

**Unassign convention:** To clear an assignee, callers pass `ownerPersonId: ""` (empty string). Since `""` is non-nil, it gets included in the JSON body as `"owner_person_id": ""`, and the backend clears both `owner_person_id` and `raw_owner_text`. To assign a person, pass their ID. To leave the assignee unchanged, don't pass the parameter at all (it stays `nil`).

- [ ] **Step 2: Verify the existing callers still compile**

The `ownerPersonId` parameter has a default value of `nil`, so all existing callers in `ActionItemsViewModel` and `MeetingDetailViewModel` continue to work without changes.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/Services/APIClient.swift
git commit -m "feat(api-client): add ownerPersonId parameter to updateTask"
```

---

### Task 3: Frontend — Add `updateTaskOwner` to MeetingDetailViewModel

**Files:**
- Modify: `apps/macos/PersonalAIMeetingAssistant/ViewModels/ViewModels.swift` (line ~418, after `toggleTaskStatus`)

- [ ] **Step 1: Add `updateTaskOwner` method**

Add this method after the existing `toggleTaskStatus` method (around line 434, before the closing `}` of the class):

```swift
func updateTaskOwner(task: MeetingTask, personId: String?) async {
    // Optimistic update
    let previousOwnerId = task.ownerPersonId
    let previousOwnerText = task.rawOwnerText

    if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
        if let pid = personId, !pid.isEmpty {
            // Assign to person
            let person = people.first { $0.id == pid }
            tasks[idx].ownerPersonId = pid
            tasks[idx].rawOwnerText = person?.displayName
        } else {
            // Unassign
            tasks[idx].ownerPersonId = nil
            tasks[idx].rawOwnerText = nil
        }
    }

    do {
        let assignId: String? = (personId != nil && !personId!.isEmpty) ? personId : ""
        let updated = try await APIClient.shared.updateTask(taskId: task.id, ownerPersonId: assignId)
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = updated
        }
    } catch {
        errorMessage = error.localizedDescription
        // Revert on error
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].ownerPersonId = previousOwnerId
            tasks[idx].rawOwnerText = previousOwnerText
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/ViewModels/ViewModels.swift
git commit -m "feat(vm): add updateTaskOwner method to MeetingDetailViewModel"
```

---

### Task 4: Frontend — Update SummaryView with assignee dropdown

**Files:**
- Modify: `apps/macos/PersonalAIMeetingAssistant/Features/MeetingDetail/MeetingDetailView.swift` (lines 380–505 for SummaryView, and lines 123–133 for the call site)

- [ ] **Step 1: Update the SummaryView signature and call site**

First, update the call site in `MeetingDetailView` (around line 123). Change from:

```swift
SummaryView(
    summary: vm.summary,
    tasks: vm.tasks,
    isSummarizing: vm.isSummarizing,
    onGenerate: {
        Task { await vm.generateSummary() }
    },
    onTaskToggle: { task in
        Task { await vm.toggleTaskStatus(task) }
    }
)
```

To:

```swift
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
```

Then update the `SummaryView` struct signature (around line 380):

```swift
struct SummaryView: View {
    let summary: MeetingSummary?
    let tasks: [MeetingTask]
    let people: [Person]
    let speakers: [SpeakerCluster]
    let isSummarizing: Bool
    let onGenerate: () -> Void
    let onTaskToggle: (MeetingTask) -> Void
    let onUpdateOwner: (MeetingTask, String?) -> Void

    /// People who appeared as speakers in this meeting, resolved from speaker clusters.
    var meetingPeople: [Person] {
        let personIds = speakers.compactMap { $0.assignedPersonId }
        let uniqueIds = Set(personIds)
        return uniqueIds.compactMap { id in
            people.first { $0.id == id }
        }
    }
```

- [ ] **Step 2: Replace the read-only assignee text with a Menu dropdown**

Replace the current task row rendering (lines ~451–472) with the new assignee chip. Change from:

```swift
ForEach(tasks) { task in
    HStack(alignment: .top, spacing: 12) {
        Button {
            onTaskToggle(task)
        } label: {
            Image(systemName: task.status.lowercased() == "completed" ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(task.status.lowercased() == "completed" ? .green : .secondary)
                .font(.title3)
        }
        .buttonStyle(.plain)
        VStack(alignment: .leading, spacing: 4) {
            Text(task.description).font(AppTheme.Fonts.body)
            if let w = task.rawOwnerText, !w.isEmpty {
                Text("Assignee: \(w)")
                    .font(AppTheme.Fonts.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .opacity(isSummarizing ? 0.4 : 1)
    .padding(.vertical, 4)
}
```

To:

```swift
ForEach(tasks) { task in
    TaskRowView(
        task: task,
        meetingPeople: meetingPeople,
        isDimmed: isSummarizing,
        onToggle: onTaskToggle,
        onUpdateOwner: onUpdateOwner
    )
}
```

- [ ] **Step 3: Add the `TaskRowView` subcomponent**

Add this new private struct inside `MeetingDetailView.swift`, after the `SummaryView` closing brace (before the `durationString` helper):

```swift
// MARK: - Task Row with Assignee Dropdown

private struct TaskRowView: View {
    let task: MeetingTask
    let meetingPeople: [Person]
    let isDimmed: Bool
    let onToggle: (MeetingTask) -> Void
    let onUpdateOwner: (MeetingTask, String?) -> Void

    private var isDone: Bool { task.status.lowercased() == "completed" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Checkbox
            Button {
                onToggle(task)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? AppTheme.Colors.accentGreen : AppTheme.Colors.tertiaryText)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            // Description + assignee
            VStack(alignment: .leading, spacing: 4) {
                Text(task.description)
                    .font(AppTheme.Fonts.body)
                    .foregroundStyle(isDone ? AppTheme.Colors.tertiaryText : AppTheme.Colors.primaryText)
                    .strikethrough(isDone, color: AppTheme.Colors.tertiaryText)

                // Assignee chip
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
        (task.rawOwnerText ?? "").isEmpty ? AppTheme.Colors.tertiaryText : AppTheme.Colors.brandPrimary
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `cd apps/macos && xcodebuild -project KlarityApp.xcodeproj -scheme PersonalAIMeetingAssistant build`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/PersonalAIMeetingAssistant/Features/MeetingDetail/MeetingDetailView.swift
git commit -m "feat(notes): add assignee dropdown with meeting people to task rows"
```

---

### Task 5: Integration test — verify full flow

**Files:**
- No new files — manual verification

- [ ] **Step 1: Start the backend**

Run: `cd backend && source venv/bin/activate && uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload`

- [ ] **Step 2: Build and run the frontend in Xcode**

Press Cmd+R in Xcode.

- [ ] **Step 3: Test the assignee dropdown**

1. Open a meeting that has a summary with action items.
2. Go to the Notes tab.
3. Verify each task row shows an assignee chip (either the name or "Unassigned").
4. Click the chip — verify a dropdown appears with meeting people.
5. Select a person — verify the chip updates to show that person's name.
6. Click the chip again — verify "Unassign" option appears (since person is assigned).
7. Click "Unassign" — verify the chip reverts to "Unassigned".
8. Go to the Action Items view — verify the same task shows the updated assignee.

- [ ] **Step 4: Verify API directly**

```bash
# Get a task ID
curl http://127.0.0.1:8765/tasks | python3 -m json.tool

# Assign a person
curl -X PATCH http://127.0.0.1:8765/tasks/{task_id} \
  -H "Content-Type: application/json" \
  -d '{"owner_person_id": "{person_id}"}'

# Unassign
curl -X PATCH http://127.0.0.1:8765/tasks/{task_id} \
  -H "Content-Type: application/json" \
  -d '{"owner_person_id": ""}'
```