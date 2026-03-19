# Issue #042: Works/Editions Migration

## Summary
Restructure the core `books` table into a works/editions model. `books` becomes the logical work (title, author, subjects); new `book_editions` table carries ISBN, format, cover, page count. Update all foreign keys, Ecto schemas, and existing tests.

## User Stories
US-1.1.1, US-1.1.6, US-1.1.8, US-1.4.1, US-1.5.4, US-2.2.1, US-9.2.1

## Goal
The data model correctly represents the real-world relationship: one work → many editions. Every existing test passes against the new schema. The ISBN hard gate is enforced at `book_editions.isbn`.

## Technical Requirements
- New migration: `create_book_editions` — `id UUID PK`, `book_id FK NOT NULL`, `isbn TEXT UNIQUE NOT NULL`, `format ENUM(hardcover, softcover, kindle, ebook, audiobook, other)`, `is_primary BOOLEAN DEFAULT false`, `cover_image_url`, `page_count`, `publisher`, `publication_year`, `language`, `open_library_edition_id`, `google_books_id`. Index on `book_id`.
- Alter `books`: drop `isbn`, `cover_image_url`, `page_count`, `publisher`, `publication_year`, `language`, `open_library_id`, `google_books_id`. Add `open_library_work_id TEXT`.
- Data migration: for each existing `books` row, create a `book_editions` row with `is_primary = true`, moving the dropped columns.
- Update FKs: `price_snapshots.book_id` → `price_snapshots.edition_id` (FK to `book_editions`). Same for `uploaded_images` and `partner_inventory`.
- Drop `formats TEXT[]` from `bookshelf_placements`.
- Change `bookshelf_placements.listing_mode` enum from `(open, offers, closed_bid)` to `(fixed, offers)`.
- New Ecto schema: `Stacks.Books.Edition` (table `op.book_editions`).
- Update `Stacks.Books.Book` schema: remove ISBN and edition-specific fields.
- Update `Stacks.Shelving.Placement` schema: remove `formats` field.
- Update all existing tests to work with works/editions.
- See `docs/technical-architecture.md` section 7 for full schema specification.

## Definition of Done
- [ ] Migrations run without error (forward and rollback)
- [ ] `book_editions.isbn` has UNIQUE constraint
- [ ] `book_editions.book_id` has index
- [ ] Existing books data migrated to editions (no data loss)
- [ ] All Ecto schemas compile and match the new table structure
- [ ] `mix test` passes — all existing tests updated for works/editions
- [ ] `mix credo --strict` passes
- [ ] `dbt run --select stg_books stg_book_editions` succeeds (Task 044 creates the dbt models, but the tables must exist)

## Dependencies
None — this is the first task in the sequence.

## Agent Assignment
database-agent + elixir-agent

## Progress Notes
