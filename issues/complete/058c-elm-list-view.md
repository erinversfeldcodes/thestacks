# Issue #058c: Elm — List View Toggle

## Summary
Build a sortable table list view as an alternative to the visual bookshelf spine view.

## User Stories
US-19.2.1 (list view toggle)

## Goal
Users who prefer information density can toggle to a sortable table view of their shelves.

## Technical Requirements
- `ShelfViewMode` type: `SpineView | ListView`
- `Components.ViewModeToggle` — grid/list icon pair in shelf header
- `Components.BookList` — sortable table with columns:
  - Cover thumbnail, title, author, page count, date added, shelf, formats, wear state
- Click column header to sort (title A-Z, author A-Z, date newest/oldest, pages)
- Click row opens book detail overlay
- Preference stored via port → `localStorage`
- Default: SpineView; ListView for `prefers-reduced-motion`

## Scope Check
- Create `Components.ViewModeToggle`
- Create `Components.BookList`
- Modify `Page.Bookshelf` (conditional render)
- ~250 LOC

## Dependencies
#057a (overlay for row click)

## Definition of Done
- [ ] Toggle switches between spine and list view
- [ ] Table renders with all columns
- [ ] Sorting works on all columns
- [ ] Row click opens overlay
- [ ] Preference persists in localStorage
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
