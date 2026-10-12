# US-1.5.4 — Format Tracking

> Written 2026-08-20. This story was **built and shipped without a story file** — the code has
> existed for some time while `docs/user-stories.md` and this directory had nothing for it, so the
> only description of the behaviour was the mapping's implementation table. Reconstructed here from
> the shipped code, which is the source of truth for a story documented after the fact.

## 1. User Story

> **As a** reader who owns a book in more than one form, **I want to** record which formats I own
> **so that** my shelf reflects the copies I actually have rather than a single anonymous entry.

**What the user wants to accomplish:** say "I own this in paperback *and* audiobook" without
creating a second shelf entry or pretending the ebook is a different book.

**How they accomplish it:**
1. The reader opens a book they have already shelved.
2. Beneath the shelf controls they see three toggles: physical, ebook, audiobook.
3. They tap the formats they own. The set is saved as a whole, not as a stream of deltas.
4. The buttons reflect the saved state; a rejected save rolls the button back and says so.

**Acceptance criteria:**
- Only the owner of the placement sees the picker. It is a claim about *their* copies.
- The three formats are independent — any subset, including none, is valid.
- A save failure restores the previous selection rather than leaving the UI asserting something
  the server did not accept.
- No ISBN is required and no new edition row is created. Which editions of a work exist is a
  different question from which copies this reader owns (that is US-1.1.5 / the editions model).

## 2. UI Interaction Flow

### Happy path
1. Reader opens `/books/:id` (or the overlay) for a book they own.
2. `Page.BookDetail.viewFormatsOnShelf` renders `Components.FormatPicker` with the placement's
   current `formats`.
3. Reader toggles one; the whole resulting set is sent.
4. On success the picker shows the new set.

### Sad paths
- **Save rejected** → the toggle rolls back to the last saved set and an error is shown. The UI
  never keeps an optimistic state the server refused.
- **Not the owner** → the picker is not rendered at all; there is nothing to press.

### Elm state machine
- **Page module**: `Page.BookDetail`, delegating to `Components.FormatPicker`
- **Msg flow**: toggle → `Api.updatePlacementFormats` → response → model updated or rolled back
- **Wire encoding**: `Types.Placement.formatToString` / `parseFormat`

## 3. API Calls

### `PUT /api/placements/:id/formats`
- **Auth**: required
- **Controller**: `StacksWeb.BookshelfPlacementController.update_formats/2`
- **Context**: `Stacks.Shelving.update_placement_formats/3`
- **Request body**: `{ formats: ["physical", "ebook", "audiobook"] }` — the complete set
- **Response (success)**: `{ placement: { id, formats } }`, serialised by
  `ProtoJSON.placement_formats/1`
- **Ownership**: checked against the placement's bookshelf; a placement the caller does not own is
  not updatable.

## 4. Auth & Middleware Guards

Authenticated pipeline; ownership verified in the controller against the placement's bookshelf
owner. No age gate and no visibility resolution — a reader's own format claim is not published to
anyone else.

## 5. Database Interactions

### Write: replace the format set
- **Table**: `op.bookshelf_placements`, column `formats` (`{:array, :string}`, default `[]`)
- **Operation**: UPDATE, **whole-list replacement, not a delta.** The client sends the resulting
  set and the server stores it; there is no add/remove endpoint and no merge semantics to get
  wrong on a retry.
- **Schema module**: `Stacks.Shelving.Placement`

## 6–11. Events, Jobs, External Services, Storage, Cache, dbt

**None, deliberately.** A format claim emits no event, enqueues no job, calls no external service,
touches no storage or cache, and feeds no dbt model. `stg_book_editions` models the *work's*
editions, which is a different question from which copies a reader owns — conflating the two is
the mistake this story exists to avoid.

## 12. Elm Frontend State Machine (Detail)

- **Route**: reached through `Route.BookDetail String` (`/books/:id`) or the book-detail overlay;
  the picker itself is not routed.
- **Init**: no extra fetch — the formats arrive with the placement in the book-detail payload.
- **View**: `Components.FormatPicker`, three toggle buttons, rendered only when the viewer owns the
  placement.

## Test coverage

Elm tests cover the picker's toggle-and-save cycle including the rollback; the Elixir side covers
`update_placement_formats/3` and the controller's ownership check. See the mapping's US-1.5.4 block
for the current file-level citations, which the `check-mapping-truth.sh` gate keeps honest.
