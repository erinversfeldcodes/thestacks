# Issue #057a: Elm — Book Detail Overlay

## Summary
Convert BookDetail from a full page to a dismissable overlay that appears on top of the current page.

## User Stories
US-1.4.1 (book detail overlay)

## Goal
Clicking a book spine opens a detail overlay without changing the URL. The current shelf/page remains visible (blurred) behind it.

## Technical Requirements
- `Maybe BookDetailOverlay` in Main model (UI state, not a route)
- Opens on: spine click, search result click, catalogue item click
- Dismiss via: X button, click outside overlay, Escape key
- URL does NOT change — browser back button works naturally
- `role="dialog"` with `aria-label="Book details: [Title] by [Author]"`
- Blurred background (`backdrop-filter: blur`) behind overlay
- Shows: book metadata, editions list, per-edition prices (stub), reviews (stub), author card (stub), "My Writing" section (from API), placement info
- Fetch book detail via `GET /api/books/:id` when overlay opens
- Use `RemoteData` for the fetch state

## Scope Check
- Modify `Main.elm` (add overlay state + messages)
- Modify `Components.Spine` (click opens overlay instead of navigating)
- Modify/create `Page.BookDetail` (render as overlay, not page)
- ~300 LOC

## Definition of Done
- [ ] Spine click opens overlay; URL unchanged
- [ ] Dismiss via X, Escape, click-outside all work
- [ ] `role="dialog"` set with descriptive aria-label
- [ ] Book data fetched on open, loading state shown
- [ ] Blurred background visible
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
