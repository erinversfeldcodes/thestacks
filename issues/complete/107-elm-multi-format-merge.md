# Issue #107: Elm — Multi-Format Book Merge Flow

## Summary
Complete the Elm frontend for multi-format book merging (US-1.1.8). When a user uploads a book that matches an existing work in a different format, prompt them to merge rather than creating a duplicate.

## User Stories
US-1.1.8 (multi-format merge)

## Goal
User owns "The Great Gatsby" as hardcover. They upload the Kindle edition. Instead of creating a duplicate, the system prompts: "You own The Great Gatsby as Hardcover. Add Kindle edition?" On confirm, the new ISBN is linked to the existing book via `POST /api/books/:id/merge-format`.

## Backend Status
Complete — `POST /api/books/:id/merge-format` exists (implemented in #046). Accepts `{ isbn, format_label }` and links a new edition to an existing work. The `Books.confirm/2` context function already detects same-work fuzzy matches via title+author (Jaro-Winkler > 0.8).

## Technical Requirements

**Detection:**
- After `POST /api/books/confirm` returns a merge suggestion (check API response for `merge_candidate` field or similar), show the merge prompt instead of proceeding to shelf selection
- If `Books.confirm/2` returns `{:ok, :merge_prompt, existing_book, new_isbn}`, the Elm page should display the merge UI

**Merge prompt UI (in Page.Upload):**
- "You own [Title] as [existing format]. Add [new format] edition?"
- Show both editions: existing (left) + new (right) with format labels
- "Yes, merge editions" (primary) → calls `POST /api/books/:id/merge-format`
- "No, add as separate book" (secondary) → proceeds to normal shelf selection
- On merge success: "[Title] now has [N] editions" with link to book detail

**API integration:**
- Add `Api.mergeFormat : String -> { isbn : String, formatLabel : String } -> String -> (Result Http.Error value -> msg) -> Cmd msg`
- Wire into Upload.update for the merge confirmation flow

**Replace the current stub:**
- Remove the `ConfirmDuplicateMove` TODO stub in Upload.elm
- Replace with proper merge flow using the real endpoint

## Scope Check
- Modify `Page.Upload` (merge prompt view + messages)
- Modify `Api.elm` (add mergeFormat)
- ~150 LOC

## Dependencies
- #057b (upload verification step — done, has the TODO stub to replace)
- #046 backend (merge-format endpoint — done)

## Definition of Done
- [ ] Merge prompt appears when duplicate work detected
- [ ] "Yes, merge" calls POST /api/books/:id/merge-format
- [ ] "No, add separate" proceeds to normal flow
- [ ] Success shows edition count
- [ ] ConfirmDuplicateMove TODO stub removed
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
