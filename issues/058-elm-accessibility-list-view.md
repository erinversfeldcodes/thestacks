# Issue #058: Elm — Accessibility (ARIA, Keyboard Nav, List View Toggle)

## Summary
Add ARIA labels to all visual elements, implement full keyboard navigation, and build the list view toggle as an alternative to the visual bookshelf.

## User Stories
US-19.1.1 (ARIA labels), US-19.1.2 (keyboard navigation), US-19.2.1 (list view toggle)

## Goal
Screen reader users can navigate the platform meaningfully. Keyboard-only users can browse shelves, open book details, and dismiss overlays. Users who prefer information density can toggle to a sortable list view.

## Technical Requirements

**ARIA labels (US-19.1.1):**
- Every `Components.Spine` element: `aria-label="Book: [Title] by [Author], [Pages] pages, [wear state]"`
- Bookshelf containers: `role="list"`, `aria-label="[Shelf Name] — N books"`
- Book detail overlay: `role="dialog"`, `aria-label="Book details: [Title] by [Author]"`
- Upload progress: `aria-live="polite"` regions announcing "Processing image…", "Book identified: [Title]", "Added to [Shelf]"
- User menu dropdown: `aria-label="User menu"`
- Navigation items: descriptive labels
- Wear state in ARIA label: "(well-loved, read 3 times)"

**Keyboard navigation (US-19.1.2):**
- `Tab` moves focus: nav items → shelf content → individual spines
- Arrow keys within shelf grid: left/right within row, up/down between rows
- `Enter` on focused spine opens book detail overlay
- `Escape` closes detail overlay, returning focus to triggering spine
- Tab within overlay moves between interactive elements (shelf picker, format toggles, links)
- Skip link: hidden "Skip to main content" link before navigation
- Visible focus indicators styled with platform aesthetic (warm amber outline)

**List view toggle (US-19.2.1):**
- `ShelfViewMode` type: `SpineView | ListView`
- `Components.ViewModeToggle` — grid/list icon pair in shelf header
- `Components.BookList` — sortable table: cover thumbnail, title, author, page count, date added, shelf, format indicators, wear state (text label)
- Click column header to sort (title A-Z, author A-Z, date newest/oldest, pages)
- Click row opens book detail overlay
- Preference stored via `setViewMode` port → `localStorage`
- Default: `SpineView` for most users, `ListView` for users with `prefers-reduced-motion`

## Definition of Done
- [ ] All spines have descriptive `aria-label` attributes
- [ ] Bookshelf containers use `role="list"` with shelf name and book count
- [ ] Book detail overlay uses `role="dialog"` with focus trapping
- [ ] Upload progress announced via `aria-live` regions
- [ ] Tab, arrow keys, Enter, Escape all work as specified
- [ ] Focus returns to triggering spine when overlay closes
- [ ] Skip link present and functional
- [ ] Focus indicators visible and styled
- [ ] List view toggle renders sortable table
- [ ] Sorting by all columns works
- [ ] View preference persists in localStorage
- [ ] `elm-format --validate src/` passes

## Dependencies
Issue #057 (overlay + settings must exist for focus trapping and ARIA integration)

## Agent Assignment
elm-agent

## Progress Notes
