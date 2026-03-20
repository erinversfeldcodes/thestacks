# Issue #075: confirm/2 — Create Placement for Existing-ISBN Books

## Summary
`Books.confirm/2` currently returns `{:ok, :existing, book}` when the ISBN already exists in the platform, but does not create a shelf placement for the user. This means a user who adds a book already in the catalogue ends up with no placement — the book never lands on any shelf.

## User Stories
US-1.1.6 (duplicate detection), US-1.1.1 (two-step upload — success path must place book on shelf)

## Goal
When `confirm/2` is called with an ISBN that already exists in `book_editions`, the function should create a placement for the user on the specified shelf (defaulting to `"wishlist"`) and return the book + placement data. The controller response should indicate whether this is a newly-created book or an existing-catalogue book so the Elm frontend can display the appropriate state ("You already have this book" vs "Added to your wishlist").

## Technical Requirements

- `Books.confirm/2` — when `find_existing(isbn)` returns a `%Book{}`:
  - Check if the user already has an active placement for that book (query `bookshelf_placements` by `book_id` + `user_id` via bookshelf owner)
  - If yes → return `{:ok, :already_placed, book, placement}` (no new placement created)
  - If no → create a placement on the requested shelf (default `"wishlist"`) and return `{:ok, :existing, book, placement}`
- `BookController.confirm/2` — map new return values:
  - `{:ok, :created, book, placement}` → 201
  - `{:ok, :existing, book, placement}` → 200 with `"source": "catalogue"` in response
  - `{:ok, :already_placed, book, placement}` → 200 with `"source": "collection"` in response
- Response body must include both `book` and `placement` fields in all success cases
- The existing `{:ok, :existing, book}` (no placement) return path must be removed

## Definition of Done
- [ ] `confirm/2` creates a placement for existing-ISBN books when user doesn't already have one
- [ ] `confirm/2` returns placement data in all success return tuples
- [ ] Controller maps all three `:created` / `:existing` / `:already_placed` cases correctly
- [ ] `BookController` confirm tests updated to assert placement in response body
- [ ] `Books.confirm/2` unit tests cover all three cases
- [ ] `mix test` passes, `mix credo --strict` clean

## Dependencies
Issue #046 (confirm/2 must exist — complete), Issue #042 (bookshelf_placements table must exist)

## Agent Assignment
elixir-agent

## Progress Notes

**2026-03-19 — Complete. All gates passed.**

- `Books.confirm/2` now returns `{:ok, :existing, book, placement}` (creates placement) or `{:ok, :already_placed, book, placement}` (user already owns it)
- `place_or_return_existing/3` + `create_placement_for_existing/3` private helpers keep nesting ≤ 2
- `BookController.confirm/2` maps all three success tuples; response includes `placement` and `source` key
- `format_placement_or_nil/1` extended to include `book_id`
- 542 tests, 0 failures; coverage 84.7%; Credo clean; Sobelow unchanged
