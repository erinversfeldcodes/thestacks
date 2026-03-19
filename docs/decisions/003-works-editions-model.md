# ADR 003: Works/Editions Data Model (books = work, book_editions = edition)

**Status:** Accepted
**Date:** 2026-03-05 (revised 2026-03-17)
**Deciders:** Platform owner
**Technical area:** Data model, core book management

---

## Context

A book is not a single entity. "Dune" by Frank Herbert is a *work* — but it exists as a 1965 first edition hardcover, a 2019 Ace mass market paperback, a Kindle edition, and an Audible audiobook. Each format has:
- Its own ISBN (different for hardcover, Kindle, audiobook)
- Its own cover image
- Its own page count (or duration for audio)
- Its own current price at each bookshop
- Its own publisher and publication year

But all formats share:
- Title and author
- Subjects and BISAC codes
- Open Library work ID
- Review aggregation (reviews are about the work, not a specific format)
- Reading history ("I read Dune" — not "I read ISBN 978-0-441-17271-9")

The naive alternative is a flat `books` table where each row has an ISBN. This approach breaks when a user owns multiple formats of the same book: two rows for the same work, duplicated metadata, no way to aggregate reviews or reading history across formats.

**Open Library's model:** Open Library distinguishes works (`/works/OL27448W`) from editions (`/books/OL7353617M`). Aligning with their model simplifies ISBN resolution — the API response maps naturally to our schema.

**User story driving this:** US-1.1.8 — "If I upload a new format of a book I already own, the platform should offer to add it as an additional format rather than treating it as a duplicate." This is only implementable with a works/editions split.

---

## Decision

**The `books` table represents a work. The `book_editions` table represents a specific edition (ISBN, format, cover).**

**`op.books` (works) contains:**
- `title`, `author_id`, `description`, `subjects`, `bisac_codes`
- `visibility_tier` — content moderation result (work-level: if any edition is age-gated, the work is gated)
- `open_library_work_id`
- No ISBN — ISBN lives exclusively on `book_editions`

**`op.book_editions` contains:**
- `isbn UNIQUE NOT NULL` — the hard gate (see ADR for ISBN Hard Gate)
- `book_id` — FK to `books`
- `format` — `ENUM('hardcover', 'softcover', 'kindle', 'ebook', 'audiobook', 'other')`
- `is_primary BOOLEAN` — determines which edition's cover and page count are used for shelf rendering
- `cover_image_url`, `page_count`, `publisher`, `publication_year`, `language`
- `open_library_edition_id`, `google_books_id`

**What references works vs. editions:**

| Entity | References | Rationale |
|--------|-----------|-----------|
| `bookshelf_placements` | `books` (work) | You shelve a book, not a format |
| `review_snapshots` | `books` (work) | Reviews are about the story, not the binding |
| `post_book_associations` | `books` (work) | Blog associations are about the work |
| `bookshelf_placement_history` | `books` (work) | Reading journey is about the work |
| `price_snapshots` | `book_editions` | Prices are format- and store-specific |
| `partner_inventory` | `book_editions` (via ISBN) | Partner stock is a specific edition |
| `uploaded_images` | `book_editions` | A photo identifies a specific edition |

**Multi-format merge flow (US-1.1.8):** When a user uploads a new format of an existing work:
1. ISBN resolves to Open Library — edition found.
2. Fuzzy match (Jaro-Winkler > 0.8) against existing work by title + author.
3. If match found: offer "You own [Title] as [format]. Add [new format]?" — creates a new `book_editions` row under the existing `books` row. No new shelf placement.
4. If no match: create new `books` work + first `book_editions` edition, then placement.

**Primary edition:** `is_primary = true` on one edition per work. Set automatically for the first edition added. Used for default cover image URL and spine thickness (from `page_count`). When the primary edition is deleted, the next-oldest edition becomes primary.

**Constraint:** A work must always have at least one edition. Deleting the last edition of a work is blocked at the context layer (`Stacks.Books`).

---

## Consequences

**Positive:**
- Multi-format ownership is first-class — users can own hardcover + Kindle + audiobook of the same work without data duplication.
- Review aggregation, reading history, and blog associations are work-scoped — semantically correct.
- Price tracking is edition-scoped — semantically correct (hardcover and Kindle have different prices).
- Aligns with Open Library's work/edition model — ISBN resolution maps cleanly.
- `read_count` is derived from `bookshelf_placement_history` (no denormalised counter to keep in sync).

**Negative:**
- Two-table join required for most book displays: `books JOIN book_editions ON book_editions.book_id = books.id`.
- The primary edition concept adds complexity — `is_primary` must be maintained correctly when editions are added or removed.
- "Which format did I read?" is not tracked — placement history references the work, not the edition. If a user wants to record "I read the audiobook version," the current model cannot capture this. Accepted trade-off for Phase 1.
- Partners submit ISBNs (edition-level) but the platform shows work-level data — the join path is `partner_inventory.isbn → book_editions.isbn → book_editions.book_id → books`.

**Known limitation:**
- If two editions of the same work have substantially different content (annotated editions, abridged audiobooks) they share the same work record. No variant/edition-type distinction is modelled at the work level. This is acceptable for Phase 1.
