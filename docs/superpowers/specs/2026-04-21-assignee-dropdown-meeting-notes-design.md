# Assignee Dropdown in Meeting Notes

**Date:** 2026-04-21
**Status:** Approved

## Problem

Tasks extracted by the LLM during summarization show assignees as read-only text in the Meeting Notes (Summary) tab. Users cannot assign or re-assign tasks from within the meeting context, where they can see who was present.

## Decision

Add an assignee dropdown to each task row in the Notes tab, populated with people from the meeting. Selecting a person links the task to that Person record via `owner_person_id`.

## Design

### Backend Changes

1. **`TaskUpdate` schema** — add `owner_person_id: Optional[str] = None`
2. **`update_task` endpoint** — when `owner_person_id` is provided:
   - Look up the `Person` record
   - Set `task.owner_person_id` to the person's ID
   - Set `task.raw_owner_text` to the person's `display_name` (keeps both fields in sync)
   - If `owner_person_id` is `""`: clear both `owner_person_id` and `raw_owner_text` (unassign)

### Frontend — Data Layer

1. **`APIClient.updateTask`** — add `ownerPersonId: String?` parameter
2. **`MeetingTask`** — already has `ownerPersonId` field, no change needed

### Frontend — SummaryView

1. Accept new parameters: `people: [Person]`, `speakers: [SpeakerCluster]`
2. Derive meeting people list: from `speakers`, collect all `assignedPersonId` values, look up matching `Person` records
3. Replace read-only "Assignee: X" text with a clickable assignee chip:
   - Shows current assignee name or "Unassigned" in secondary color
   - Clicking opens a native SwiftUI `Menu`
   - Menu contains: "Unassign" at top (if currently assigned), then each meeting person's `displayName`
4. New callback: `onUpdateOwner: (MeetingTask, String?) -> Void` where the optional String is a person ID (nil = unassign)

### Frontend — MeetingDetailViewModel

1. Add `updateTaskOwner(task: MeetingTask, personId: String?)` method
2. Calls `APIClient.shared.updateTask(taskId:ownerPersonId:)` with optimistic local state update
3. On error, reverts local state and shows error message

### Scope

- Notes tab only. ActionItemsView keeps its current free-text assignee editing.
- Task creation by the LLM still uses `raw_owner_text` only — linking happens via the dropdown.
- `TaskOut` schema already returns `owner_person_id`, no change needed.

## Approach

Native SwiftUI `Menu` + `Picker` (not a custom popover). Meetings typically have 2-5 speakers, so search is unnecessary. Native menu provides keyboard navigation and accessibility for free.

## Out of Scope

- Changing ActionItemsView assignee editing
- Auto-linking LLM-extracted assignee names to Person records
- Task reassignment across meetings
- Search/filter in the dropdown