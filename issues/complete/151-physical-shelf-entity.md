# Issue #151: Physical Shelf Entity (Bookcase Rows)

## Summary
The UI renders books in horizontal rows within a bookcase. Currently the grouping is computed entirely client-side by filling rows to a fixed pixel width. There is no backend concept of a physical shelf (row) within a bookcase, meaning shelf assignment cannot be persisted, reordered server-side, or queried. This issue introduces the `Shelf` entity between `Bookshelf` (the named collection) and `Placement` (the book-on-shelf record).

## User Stories
Implied by bookshelf UI (bookcase aesthetic with 3–4 horizontal shelves); US-7.2 (marketplace: book on a specific shelf)

## Goal
A `Bookshelf` contains one or more `Shelf` records (rows). Each `Placement` belongs to a specific `Shelf`. Shelf order within a bookcase is user-controlled. The API supports reordering shelves and moving a placement between shelves.

## Scope Check
- Does this issue touch more than 3 controllers? → No — `ShelfController`, additions to `BookshelfPlacementController`.
- Does this issue add more than 2 new endpoints? → Yes (4 endpoints) — necessary for shelf management. Acceptable for a single bounded domain.
- Does this issue exceed ~300 lines of production code? → Migration + context ~150 LOC, controllers ~100 LOC, Elm ~200 LOC.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**Migration:**
```sql
CREATE TABLE op.shelves (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bookshelf_id  uuid NOT NULL REFERENCES op.bookshelves(id) ON DELETE CASCADE,
  position      integer NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (bookshelf_id, position)
);

-- Back-fill: create one shelf per bookshelf for existing placements
INSERT INTO op.shelves (bookshelf_id, position)
SELECT id, 0 FROM op.bookshelves;

-- Add shelf_id to placements (nullable during migration, not null after back-fill)
ALTER TABLE op.bookshelf_placements ADD COLUMN shelf_id uuid REFERENCES op.shelves(id);
UPDATE op.bookshelf_placements p
  SET shelf_id = (SELECT id FROM op.shelves s WHERE s.bookshelf_id = p.bookshelf_id LIMIT 1);
ALTER TABLE op.bookshelf_placements ALTER COLUMN shelf_id SET NOT NULL;
```

**Proto:** Add `Shelf` message to `proto/stacks/shelving/v1/shelf.proto`. Run `mix proto.sync`.

**`Stacks.Shelving` additions:**
```elixir
list_shelves(bookshelf_id)          # → [Shelf] ordered by position
create_shelf(bookshelf_id, user_id) # → {:ok, Shelf} | {:error, :unauthorized}
delete_shelf(shelf_id, user_id)     # → :ok | {:error, :unauthorized | :not_empty}
  # :not_empty if shelf has placements

reorder_shelves(bookshelf_id, user_id, shelf_ids_in_order)
  # → :ok | {:error, :unauthorized | :invalid_ids}

move_placement_to_shelf(placement_id, shelf_id, user_id)
  # → {:ok, Placement} | {:error, :unauthorized | :wrong_bookshelf}
```

**Routes:**
```
get    "/bookshelves/:name/shelves",                  ShelfController, :index
post   "/bookshelves/:name/shelves",                  ShelfController, :create
delete "/shelves/:id",                                ShelfController, :delete
put    "/bookshelves/:name/shelves/reorder",          ShelfController, :reorder
put    "/placements/:id/shelf",                       BookshelfPlacementController, :move_to_shelf
```

**Elm updates (`Page.Bookshelf`):**
- Replace client-side row grouping (`groupIntoRows 990`) with server-provided shelf data
- Each shelf is a `List Placement` from API; render as a horizontal bookcase row
- Drag-and-drop between shelves updates `PUT /api/placements/:id/shelf`
- "Add shelf" button appends a new empty row; "Remove shelf" (owner only) disabled if shelf has books

## Reviewer Context
- **Breaking change**: `get_bookshelf_books/2` currently returns a flat list. After this issue it should return `[{shelf: Shelf, placements: [Placement]}]`. Update the response shape carefully — Elm must be updated in lock step.
- Back-fill migration creates exactly one shelf per bookshelf so all existing placements have a valid `shelf_id`. Verify the back-fill runs before setting NOT NULL.
- `groupIntoRows 990` in `Page.Bookshelf` must be removed once shelf data comes from API.
- Drag-and-drop: use the existing `Components.DragDrop` helper if it exists; otherwise implement with `Html.Events.on "dragstart"` / `on "drop"` pair.

## Definition of Done
- [ ] Migration back-fills all existing placements with a shelf_id (zero data loss)
- [ ] `list_shelves/1` returns shelves in position order
- [ ] `delete_shelf/2` returns `:not_empty` when shelf has placements
- [ ] `move_placement_to_shelf/3` returns `:wrong_bookshelf` when shelf belongs to different bookshelf
- [ ] `GET /api/bookshelves/:name` response includes shelves with nested placements
- [ ] Elm renders books grouped by shelf rather than by pixel-width grouping
- [ ] Shelf reorder persists after page refresh
- [ ] Tests for back-fill correctness (all placements have shelf_id after migration)
- [ ] `just verify` passes

## Dependencies
Issue #131 (proto.sync), Issue #001 (Shelving context — foundation)

## Agent Assignment
elixir-agent, elm-agent

## Progress Notes
