# Issue #146: Partner Inventory & Events Sync API

## Summary
Build the inbound API that partners use to push their book inventory and events. Partners authenticate with the HMAC key from Issue #145. Inventory records are validated against the existing `Book` catalogue via ISBN. Events are attached to the partner's Third Space record.

## User Stories
US-9.2.1 Inventory Sync (JSON API), US-9.2.2 CSV Upload, US-9.3.1 Push Events, US-9.3.2 Event Dashboard

## Goal
An approved partner can push their current book stock (price, condition, availability) via a JSON API or CSV upload. They can also push upcoming events. The platform stores this data and surfaces it on book detail pages and the Third Spaces cork board.

## Scope Check
- Does this issue touch more than 3 controllers? → No — `PartnerInventoryController`, `PartnerEventController`.
- Does this issue add more than 2 new endpoints? → Yes (4 endpoints) — all partner-facing sync, bounded domain.
- Does this issue exceed ~300 lines of production code? → Borderline — CSV parser adds complexity. Split CSV into separate issue if needed.
- Does this issue combine unrelated concerns? → Inventory and events are separate but both are partner push APIs — acceptable together.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**Routes (partner-authenticated):**
```
scope "/api/partner", StacksWeb do
  pipe_through [:api, :partner_auth]  # PartnerAuthPlug from Issue #145

  post "/inventory",         PartnerInventoryController, :sync     # JSON bulk
  post "/inventory/import",  PartnerInventoryController, :import   # CSV upload
  get  "/inventory",         PartnerInventoryController, :index    # partner's own stock

  post "/events",            PartnerEventController, :create
  get  "/events",            PartnerEventController, :index
  delete "/events/:id",      PartnerEventController, :delete
end
```

**Inventory sync (`POST /api/partner/inventory`):**
- Body: `{ "inventory": [{ "isbn": "...", "price_cents": 1500, "condition": "good", "quantity": 2 }] }`
- For each item: resolve ISBN against `book_editions` table. If no match → skip and include in `unresolved` list in response.
- Upsert into `op.partner_inventory` (partner_id, book_edition_id, price_cents, condition, quantity, synced_at).
- Returns `{ "synced": 12, "unresolved": ["9781234567890"] }`.

**CSV upload (`POST /api/partner/inventory/import`):**
- Multipart `inventory` file field. Column header row required: `isbn,price_cents,condition,quantity`.
- Max 10,000 rows. Returns same `synced`/`unresolved` shape.
- Parse with `NimbleCSV`.

**Events (`POST /api/partner/events`):**
- Body: `{ "title": "...", "starts_at": "ISO8601", "ends_at": "ISO8601", "description": "...", "location": "..." }`
- Validates: `starts_at` must be future, `ends_at` > `starts_at`.
- Creates `ThirdSpaceEvent` record linked to `current_partner.third_space_id`.

**Migration:** Add `op.partner_inventory` table:
```sql
id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
partner_id       uuid NOT NULL REFERENCES op.partners(id),
book_edition_id  uuid NOT NULL REFERENCES op.book_editions(id),
price_cents      integer NOT NULL CHECK (price_cents > 0),
condition        text NOT NULL,
quantity         integer NOT NULL DEFAULT 1,
synced_at        timestamptz NOT NULL DEFAULT now(),
UNIQUE (partner_id, book_edition_id)
```

**Proto:** Add `PartnerInventoryItem` message; run `mix proto.sync`.

## Reviewer Context
- `PartnerAuthPlug` sets `conn.assigns[:current_partner]` — use this, not Guardian session, in partner controllers.
- ISBN lookup must use `book_editions.isbn` (13-digit), not `books.isbn`. Strip hyphens before lookup.
- `NimbleCSV` is already in `mix.exs` (used in scraper CSV parsing) — verify before adding.
- `ThirdSpaceEvent` changeset already exists in `Stacks.Enrichment` — reuse it.

## Definition of Done
- [ ] JSON sync returns correct `synced`/`unresolved` counts
- [ ] CSV upload with 10,001 rows returns 422 with "too many rows" error
- [ ] Unknown ISBNs included in `unresolved`, not silently dropped
- [ ] Event with `starts_at` in the past returns 422
- [ ] Partner can only view/delete their own events (not other partners')
- [ ] `PartnerAuthPlug` blocks all routes with 401 for missing key
- [ ] Tests for CSV parsing edge cases (missing header, malformed rows, BOM prefix)
- [ ] `just verify` passes

## Dependencies
#145 (Partner entity + auth plug), Issue #131 (proto.sync for schema generation)

## Agent Assignment
elixir-agent

## Progress Notes
