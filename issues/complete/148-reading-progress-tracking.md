# Issue #148: Reading Progress Tracking

## Summary
Add reading lifecycle fields to `bookshelf_placements`: reading status (to_read / reading / completed / abandoned), current page, and start/finish timestamps. Expose these through the Shelving context, API, and Elm placement cards. Enables "books in progress" filtering and future reading analytics.

## User Stories
US-2.x (reading journey management — implied across bookshelf and reading stories)

## Goal
A user can mark a placement as "currently reading", record their current page, and mark it as finished. The library view can filter to show only books in progress. Finished books show a completion date.

## Scope Check
- Does this issue touch more than 3 controllers? → No — `BookshelfPlacementController` only.
- Does this issue add more than 2 new endpoints? → No — `PUT /api/placements/:id/progress`.
- Does this issue exceed ~300 lines of production code? → Migration + context ~100 LOC, controller ~50 LOC, Elm ~150 LOC.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**Migration:** Add columns to `op.bookshelf_placements`:
```sql
reading_status  text DEFAULT 'to_read'
  CONSTRAINT reading_status_valid CHECK (
    reading_status IN ('to_read', 'reading', 'completed', 'abandoned')
  ),
current_page    integer CHECK (current_page >= 0),
started_at      timestamptz,
finished_at     timestamptz
```

**Proto:** Add fields to `BookshelfPlacement` message in `proto/stacks/shelving/v1/placement.proto`. Run `mix proto.sync`.

**`Stacks.Shelving` additions:**
```elixir
update_reading_progress(placement_id, user_id, attrs)
  # attrs: {reading_status, current_page}
  # Auto-sets started_at on first transition to :reading
  # Auto-sets finished_at on transition to :completed
  # → {:ok, Placement} | {:error, :unauthorized | :not_found | changeset}

list_in_progress(user_id)
  # → [Placement] where reading_status = 'reading', ordered by updated_at DESC
```

**Events emitted:**
- `placement.reading_started` (first transition to :reading)
- `placement.reading_completed` (transition to :completed)

**API endpoint:**
```
PUT /api/placements/:id/progress
Body: { "reading_status": "reading", "current_page": 124 }
→ 200 with updated placement | 403 | 422
```

**Elm additions (`Components.PlacementCard`):**
- Progress indicator: shows current_page / page_count (if available from edition)
- Status badge: "Reading", "Finished", "To Read", "Abandoned"
- Clicking status badge opens a small inline form to update status + current page
- Finished placements show `finished_at` date

## Reviewer Context
- `current_page` validation should check against `book_editions.page_count` if available (warn, not error, if over page count).
- `BookshelfPlacement` proto message is at `proto/stacks/shelving/v1/placement.proto` — verify path before editing.
- Auto-setting timestamps: `started_at` should only be set on the first `:reading` transition (do not overwrite if already set).
- The `to_read` default means all existing placements are unaffected by the migration.

## Definition of Done
- [ ] Migration is non-destructive; all existing placements default to `reading_status = 'to_read'`
- [ ] `update_reading_progress/3` auto-sets `started_at` on first `:reading` transition only
- [ ] `update_reading_progress/3` auto-sets `finished_at` on `:completed` transition
- [ ] `list_in_progress/1` returns only `:reading` placements
- [ ] `placement.reading_started` and `placement.reading_completed` events emitted
- [ ] API returns 403 when user does not own placement
- [ ] Elm status badge and page progress render on placement card
- [ ] Tests for all state transitions including auto-timestamp logic
- [ ] `just verify` passes

## Dependencies
Issue #131 (proto.sync — needed to regenerate placement schema)

## Agent Assignment
elixir-agent, elm-agent

## Progress Notes
