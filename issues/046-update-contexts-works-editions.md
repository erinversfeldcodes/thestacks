# Issue #046: Update Core Contexts for Works/Editions + Two-Step Upload

## Summary
Update `Stacks.Books`, `Stacks.Shelving`, and all related controllers to work with the works/editions data model. Implement the two-step upload flow (identify → verify → confirm) and multi-format merge.

## User Stories
US-1.1.1 (two-step upload), US-1.1.5 (manual ISBN — same flow), US-1.1.6 (duplicate detection against editions), US-1.1.8 (multi-format merge), US-1.5.3 (platform-wide search), US-18.1.1 (community read count)

## Goal
The upload flow is two-step: `POST /api/upload/identify` returns candidates, `POST /api/books/confirm` commits the book. Multi-format merge detects same-work-different-ISBN and offers to link editions. All book queries join through editions correctly.

## Technical Requirements

**`Stacks.Books` context updates:**
- `Books.identify/2` — orchestrates vision call + ISBN resolution, returns candidate(s) without committing. Called by `UploadController.identify/2`.
- `Books.confirm/2` — receives confirmed ISBN + shelf. Checks `book_editions` for existing ISBN (→ duplicate, US-1.1.6). Checks `books` for same-work fuzzy match on title+author (Jaro-Winkler > 0.8 → merge prompt, US-1.1.8). If new: creates work + first edition + placement. Default shelf: WishList.
- `Books.create_work_with_edition/2` — creates `books` work row + `book_editions` edition row in a transaction.
- `Books.find_same_work/2` — fuzzy title+author match against existing works.
- `Books.merge_edition/2` — creates new `book_editions` row under existing work. Sets `is_primary = false`.
- `Books.get_book_detail/1` — updated to join `book_editions`, return editions list, prices per edition, community read count from `wh.mart_community_read_count` (graceful fallback if mart doesn't exist yet).
- `Books.search_platform/2` — query across `bookshelf_placements` (public visibility), `listings` (active), `partner_inventory` (approved). Applies `resolve_visibility/2` when available (graceful fallback until Issue #047).

**Controller updates:**
- `StacksWeb.UploadController.identify/2` — new endpoint `POST /api/upload/identify`
- `StacksWeb.BookController.confirm/2` — new endpoint `POST /api/books/confirm`
- `StacksWeb.BookController.merge_format/2` — new endpoint `POST /api/books/:id/merge-format`
- Update existing `BookController.show/2` to return editions in response

**`Stacks.Shelving` updates:**
- Remove `update_placement_formats/3` — formats are now derived from editions
- `spine_data/1` — updated to derive format list from `book_editions` join
- All 5 shelves are valid move targets from any source shelf

**`Stacks.Books.ISBNResolver` updates:**
- Return both work-level and edition-level metadata from Open Library / Google Books
- Open Library work key → `books.open_library_work_id`; edition key → `book_editions.open_library_edition_id`

## Definition of Done
- [ ] `POST /api/upload/identify` returns identified candidates (with mocked vision)
- [ ] `POST /api/books/confirm` creates work + edition + placement
- [ ] Duplicate detection: existing ISBN returns existing book data
- [ ] Multi-format merge: same title+author with different ISBN triggers merge prompt; `POST /api/books/:id/merge-format` creates new edition
- [ ] `GET /api/books/:id` returns editions list with per-edition data
- [ ] Platform-wide search endpoint returns results across public shelves
- [ ] All existing tests updated and passing
- [ ] `mix credo --strict` and `mix sobelow` pass
- [ ] All shelf operations emit events via `Stacks.Events.emit/1`

## Dependencies
Issue #042 (works/editions schema must exist)

## Agent Assignment
elixir-agent (Opus — architectural judgment for works/editions model)

## Progress Notes
