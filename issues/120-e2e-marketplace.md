# Issue #120: E2E Test Suite — Marketplace Listings

## Summary
Comprehensive E2E test coverage for the marketplace listing lifecycle (US-7.1): create, activate, deactivate, mark sold, and automatic expiry.

## User Stories
US-7.1 (List a Book for Sale)

## Goal
Validate listing CRUD, the state machine (draft -> active -> removed/expired/sold), SELECT FOR UPDATE locking, placement denormalization, expiry job, and owner-only action enforcement.

## Scope Check
- Does this issue touch more than 3 controllers? No (ListingController, BookshelfPlacementController).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (single domain — marketplace).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **Create listing flow**: Navigate to `/marketplace/create` -> select book -> set condition/pricing/contact -> submit -> see "Listing Created" success view
- **Condition grades**: All 5 radio buttons render and function (New, Like New, Good, Fair, Poor)
- **Pricing modes**: Fixed (with ZAR price input) and Open to Offers radio buttons
- **Activate listing**: Click "Activate" button on draft listing -> listing transitions to active
- **No placements state**: "You have no books to list" message when user has no placements
- **Submit disabled**: Button disabled when no placement selected or no contact info entered
- **Status badges**: Correct CSS classes for draft/active/sold/expired/removed

### 2. Playwright Navigation & Visual Tests
- **Auth guard**: Unauthenticated user at `/marketplace/create` sees login page
- **My Listings navigation**: After activation, user navigated to `/marketplace/mine`
- **Error display**: Failure states shown on create and activate errors

### 3. API Endpoint Tests
- `GET /api/placements/mine` — 200 with user's placements, 401 without auth
- `POST /api/listings` — 201 with listing in "draft" status, correct fields
- `POST /api/listings` — 422 with `no_placement` when user has no placement for book
- `POST /api/listings` — 422 on changeset errors (missing required fields, invalid condition/pricing_mode)
- `POST /api/listings` — unique constraint: one active/draft listing per book per seller
- `PUT /api/listings/:id/activate` — 200, sets `listed_at` and `expires_at` (30 days)
- `PUT /api/listings/:id/activate` — 422 `invalid_transition` if not in draft status
- `PUT /api/listings/:id/activate` — 403 `unauthorized` if not the seller
- `PUT /api/listings/:id/activate` — 404 if listing not found
- `PUT /api/listings/:id/deactivate` — 200, transitions active -> removed
- `PUT /api/listings/:id/sold` — 200, transitions active -> sold with `sold_at` set
- `GET /api/listings` — 200 with active listings, newest first, limit 50 (optional auth)
- `GET /api/listings/:id` — 200 with listing details (optional auth)
- `GET /api/listings/mine` — 200 with user's own listings, 401 without auth

### 4. Database Assertion Tests
- `op.listings` record created with correct `status: "draft"`, `seller_id`, `book_id`, `pricing_mode`, `price_cents`, `condition`, `contact_info`, `currency` (default "ZAR")
- Activate: `listed_at` and `expires_at` set, `status` changed to "active"
- Deactivate: `status` changed to "removed"
- Sold: `status` changed to "sold", `sold_at` set
- **Ecto.Multi steps**: Verify `:placement` step verifies seller has active placement
- **Ecto.Multi steps**: Verify `:locked_listing` step uses `SELECT FOR UPDATE`
- **Denormalization**: `op.bookshelf_placements.listing_status` set to "active" on activate, cleared on deactivate/sold/expire
- **Unique constraint**: `listings_active_book_seller_idx` prevents duplicate active/draft listings

### 5. Event Flow Tests
- `listing.created` emitted on draft creation with `{ book_id, seller_id }`
- `listing.activated` emitted on activate with `{ book_id, seller_id }`
- `listing.removed` emitted on deactivate
- `listing.sold` emitted on mark sold
- `listing.expired` emitted by expiry job
- All events emitted via `Events.emit_safe/1` within Ecto.Multi transactions

### 6. Background Job Tests
- `ListingExpiryJob` finds active listings past `expires_at` and calls `Marketplace.expire_listing/1`
- Expiry: listing status set to "expired", placement denormalized, event emitted
- Job runs as scheduled cron

### 7. External Service Tests
- N/A — marketplace is entirely local

### 8. Storage Tests
- N/A (condition photos are future work)

### 9. Cache Tests
- N/A

### 10. dbt Model Tests
- `stg_listings` staging view materialised
- `mart_marketplace_activity` view: `SELECT status, COUNT(*) FROM stg_listings GROUP BY status`

### 11. Elm State Machine Tests
- `Page.Marketplace.CreateListing` init: `placements = Loading`, fires `Api.getMyPlacements`
- `PlacementsReceived (Ok placements)` -> `placements = Success placements`
- `PlacementSelected`, `ConditionSelected`, `PricingModeSelected`, `PriceChanged`, `ContactInfoChanged`, `DescriptionChanged` — update respective model fields
- `SubmitListing` validation: requires `selectedPlacementId` and `contactInfo`
- `ListingCreated (Ok listing)` -> `submitState = Success`, `createdListing = Just listing`
- `ActivateListing` -> `ListingActivated (Ok _)` -> OutMsg `NavigateTo Route.MarketplaceMyListings`
- Form disabled state: submit button disabled without placement or contact info

### 12. Metrics & Telemetry Tests
- `ListingExpiryJob` Oban counts: enqueued, completed, failed
- Listing CRUD endpoint success/failure counts
- State transition counts: draft->active, active->removed/expired/sold
- Ownership verification failure count
- Unique constraint violation count

## Reviewer Context
- The `mine` route for listings is mounted before the `:id` route to avoid catch-all conflicts.
- `SELECT FOR UPDATE` locking is used in all state transition Multis to prevent race conditions.
- `contact_info` max length is 500 characters.

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #120)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #120 covers a single user story — US-7.1 (List a Book
for Sale, `docs/user_stories/US-7.1-list-book-for-sale.md`) — so the matrix
is 13 layers × 1 US, with happy/sad columns per cell. The assertion
inventory for each layer is taken from Issue #120's per-layer Technical
Requirements (§1–§12 of `issues/120-e2e-marketplace.md`).

**Feature status:** the marketplace feature IS implemented — contrary to
initial expectation, this is not a greenfield audit. Existing surface:
`Stacks.Marketplace` context (`apps/core/lib/stacks/marketplace/marketplace.ex`,
with `Ecto.Multi` + `SELECT FOR UPDATE` transitions and `Events.emit_safe/1`),
`StacksWeb.ListingController`, `Stacks.Workers.ListingExpiryJob` (cron
`"0 1 * * *"` in `config.exs`), Elm pages `Page.Marketplace.{CreateListing,
Browse, MyListings, ListingDetail}` with route `/marketplace/create`, dbt
models `stg_listings` + `mart_marketplace_activity`, and an existing
Playwright suite `e2e/tests/marketplace.spec.ts`. The audit therefore
baselines real coverage rather than marking blanket "feature not implemented".

---

### Framework-layer summary

| Layer       | US-7.1 |
|-------------|--------|
| Elixir      | ⚠️ (64 tests across 4 files; gaps: 401s on mutations, unique constraint, lock semantics, event payloads) |
| Elm unit    | ⚠️ (7 Listing proto decoder tests only — zero page-level tests) |
| Elm program | ❌ (no `Page.Marketplace.*` program/state-machine tests at all) |
| Python      | n/a — vision service not involved in marketplace |
| E2E         | ⚠️ (8 Playwright tests: browse/detail/mine covered; create-listing UI flow entirely absent) |
| dbt         | ⚠️ (proto-generated generic tests only; no `accepted_values` on status, no relationships tests) |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks/marketplace_test.exs` — 34 tests (context CRUD + full state machine)
- `apps/core/test/stacks/marketplace/listing_test.exs` — 5 tests (changeset validations)
- `apps/core/test/stacks_web/listing_controller_test.exs` — 20 tests (all 7 endpoints)
- `apps/core/test/stacks/workers/listing_expiry_job_test.exs` — 5 tests
- `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` — `GET /api/placements/mine` (4 tests incl. 401)
- `e2e/tests/marketplace.spec.ts` — 8 Playwright tests
- `frontend/tests/ProtoDecoderTest.elm` — 7 Listing/ListingResponse decoder tests
- `dbt/models/staging/schema.yml` (stg_listings) + `dbt/models/marts/schema.yml` (mart_marketplace_activity) — generic column tests

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **3** |
| ⚠️ shallow | **9** |
| ❌ missing | **3** |
| n/a (covered higher up / not applicable / by-design) | **11** |

26 cells total (13 layers × happy/sad). This is the pre-implementation
baseline; Issue #120's DoD requires regenerating this audit to 0 ❌ / 0 ⚠️
after the punch list lands.

---

### Full audit tables

#### Layer 1: API Calls

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 7.1 | ✅ listing_controller_test.exs — "creates a draft listing", "activates a draft listing", "deactivates an active listing", "marks an active listing as sold", "returns active listings", "returns a listing by id", "returns the current user's listings"; bookshelf_placement_controller_test.exs — "returns summary of user's active placements". BUT index ordering ("newest first") and `limit 50` are never asserted — the index test only asserts `length(listings) == 1` on status filtering. | ⚠️ | listing_controller_test.exs — "returns 422 when seller has no placement", "returns 422 for invalid params", "returns 422 for invalid transition", "returns 403 for non-owner" (activate/sold/deactivate), "returns 404 for nonexistent listing" (activate + sold), "returns 422 for draft listing" (sold + deactivate). BUT the Issue-§3 requirement "unique constraint: one active/draft listing per book per seller" has no test at HTTP level (no "duplicate"/"constraint" match in either test file). | ⚠️ |

#### Layer 2: Auth & Middleware Guards

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 7.1 | ✅ listing_controller_test.exs — "creates a draft listing" (authenticated conn via `auth_conn/2`); index/show describes use a bare unauthenticated conn, exercising the `:optional_auth` pipeline ("returns active listings", "returns a listing by id"); ownership guard: "returns 403 for non-owner" ×3 + marketplace_test.exs — "returns :unauthorized when user is not the seller". E2E: marketplace.spec.ts — "browse page loads without authentication", "/marketplace/mine redirects unauthenticated users to login". | ✅ | ⚠️ 401 coverage is partial: listing_controller_test.exs — "returns 401 when unauthenticated" exists ONLY for `GET /api/listings/mine`; unauthenticated_redirect_test.exs — "GET /api/placements/mine without auth returns 401". No 401 tests for `POST /api/listings`, `PUT /api/listings/:id/activate`, `/deactivate`, `/sold` (4 of 5 mutation endpoints unguarded by tests). E2E auth guard for `/marketplace/create` (Issue §2) also untested — only `/marketplace/mine` redirect is. | ⚠️ |

#### Layer 3: Database Interactions

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 7.1 | ✅ marketplace_test.exs — "creates a draft listing when seller owns a placement", "transitions draft → active and sets listed_at and expires_at", "denormalizes listing_status on placement", "transitions active → removed", "clears listing_status on placement" (deactivate + sold + expire), "transitions active → sold and sets sold_at", "transitions active → expired"; listing_test.exs — "is valid with all required fields", "is invalid without price_cents", "is invalid with an unknown status/condition/pricing_mode"; marketplace_test.exs — "rejects zero price_cents", "rejects negative price_cents". `:placement` Multi step directly verified by "returns :no_placement when seller has no placement for the book" + "returns :no_placement when book_id is nil". | ✅ | ⚠️ Invalid-transition matrix is thorough (marketplace_test.exs — ":invalid_transition for active → active", "removed → active", "draft → removed", "draft → sold", "draft → expired", "expired → active is invalid", "sold → active is invalid"). BUT two Issue-§4 assertions are missing: (a) unique constraint `listings_active_book_seller_idx` (migration `20260321000001_fix_listings_timestamps_and_indexes.exs` + `unique_constraint` in `marketplace.ex:311`) has zero tests; (b) the `:locked_listing` `SELECT FOR UPDATE` step (`marketplace.ex:137`) has no lock/concurrency test — transition *validation* is tested, lock *semantics* are not (no "lock"/"FOR UPDATE" match in any test file). | ⚠️ |

#### Layer 4: Event Flow & Lifecycle

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 7.1 | ⚠️ All five events have emission tests: marketplace_test.exs — "emits listing.created event", "emits listing.activated event", "emits listing.removed event", "emits listing.sold event", "emits listing.expired event". BUT each test only asserts `Repo.exists?` on `event_type` in `event_log` — the Issue-§5 payload requirement `{ book_id, seller_id }` is never asserted (verified: the listing.created test at marketplace_test.exs:47-58 checks event_type only). | ⚠️ | ❌ No test that events are NOT emitted when a transition fails / the Multi rolls back (e.g. `listing.activated` absent after `:invalid_transition`, `listing.created` absent after `:no_placement`). The upload audit's equivalent ("image.submitted is NOT emitted when storage backend returns an error") has no marketplace counterpart. | ❌ |

#### Layer 5: Background Jobs (Oban)

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 7.1 | ⚠️ listing_expiry_job_test.exs — "expires active listings past their expires_at", "clears listing_status on placement when expiring" (status→expired + denormalization + event all covered via "emits listing.expired event" in marketplace_test.exs). BUT Issue-§6 "Job runs as scheduled cron" is unasserted — `{"0 1 * * *", Stacks.Workers.ListingExpiryJob}` exists in `apps/core/config/config.exs:54` with no test asserting the crontab registration. | ⚠️ | ⚠️ listing_expiry_job_test.exs — "does not expire active listings before their expires_at", "does not touch draft listings", "handles no expired listings gracefully". BUT no per-listing failure-isolation test (one listing failing to expire should not abort the sweep of the others). | ⚠️ |

#### Layer 6: External Service Calls

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 7.1 | n/a — marketplace is entirely local (Issue §7, US-7.1 §8): no vision, ISBN, scraper, or other external calls in listing CRUD or expiry. | n/a — same. |

#### Layer 7: Storage (R2 / Local)

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 7.1 | n/a — condition photos are explicitly future work (Issue §8); `photo_urls` is a passive array field with no upload integration yet. | n/a — same. |

#### Layer 8: Cache Interactions

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 7.1 | n/a — Issue §9 marks cache N/A; no cache sits in the listing read/write path. | n/a — same. |

#### Layer 9: dbt Model Dependencies

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 7.1 | ✅ `dbt/models/staging/stg_listings.sql` exists (proto-generated) with schema.yml tests: `not_null` + `unique` on `id`, `not_null` on `created_at`/`updated_at`; `dbt/models/marts/mart_marketplace_activity.sql` implements exactly the Issue-§10 `SELECT status, COUNT(*) ... GROUP BY status` view, with `not_null` + `unique` on `status` in `dbt/models/marts/schema.yml`. `op.listings` is registered in `sources.yml:715`. | ✅ | ❌ No `accepted_values` test on `stg_listings.status` (draft/active/removed/expired/sold), no `relationships` tests `book_id → stg_books.id` / `seller_id → stg_users.id`, and no singular test under `dbt/tests/` mentions listings. Caveat for the fix: `stg_listings` schema.yml entries are proto-generated by `mix proto.sync` — new tests must go through the proto manifest/generator or live as singular tests, not hand-edits. | ❌ |

#### Layer 10: Elm Frontend State Machine

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 7.1 | ⚠️ Decoder layer only: ProtoDecoderTest.elm — "Listing decodes all fields", "Listing encode-decode round-trip", "Listing defaults when fields absent", "ListingResponse decodes listing envelope", "ListingListResponse decodes listings array" (+2 round-trips). ZERO tests exist for `Page.Marketplace.CreateListing` (or Browse/MyListings/ListingDetail) — no file in `frontend/tests/` or `frontend/tests/Page/` matches marketplace/listing. Every Issue-§11 assertion (init `placements = Loading` + `Api.getMyPlacements`, `PlacementsReceived`, form Msgs, `SubmitListing` validation, `ListingCreated`, `ActivateListing` → `NavigateTo Route.MarketplaceMyListings`) is untested. E2E partially compensates for Browse/Detail ("active listing appears on browse page and shows contact info on detail", "listing card shows condition badge and price") but not for CreateListing. | ⚠️ | ❌ No failure-state tests at all: `PlacementsReceived (Err _)`, `ListingCreated (Err _)` error display, activate failure, submit-button-disabled validation (no placement / no contact info), "You have no books to list" empty state. Neither in elm-test nor in Playwright (marketplace.spec.ts has no `/marketplace/create` test). | ❌ |

#### Layer 11: Operational Metrics

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 7.1 | n/a — per-route latency and Oban job counts are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy) plus automatic Phoenix endpoint and Oban telemetry; no marketplace-specific SLI is defined in the gate. Per project convention, per-US repetition of firing tests adds no guarantee. | n/a | ⚠️ Issue §12 explicitly requires "ownership verification failure count" and "unique constraint violation count" metrics — no such instrumentation exists in `marketplace.ex` and no listing/marketplace mention appears in any telemetry test (`observability_telemetry_test.exs` covers vision/fuse/budget/costs only). Needs a decision: instrument + add firing tests (pattern: `upload_telemetry_test.exs`), or descope §12 and reclassify n/a. Partially blocked on instrumentation (feature gap, not just test gap). | ⚠️ |

#### Layer 12: Performance & Usability Metrics

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 7.1 | n/a — covered by SLO gate, not unit tests; in-test SLA bounds (US-7.1 §14 targets like <200ms create) are an anti-pattern under variable CI timing. Funnel metrics (activation rate, time-to-sold) are dashboard concerns derived from `mart_marketplace_activity`. | n/a — same. |

#### Layer 13: Cost Tracking

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 7.1 | n/a — no external API costs: marketplace is entirely local (US-7.1 §15 — "No external API costs"); Fly/Neon compute is covered by the cost dashboard at deploy time, and there is no per-call spend to record in `BudgetTracker`. | n/a — same. |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline).

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 US-7.1 happy | Assert `GET /api/listings` returns newest-first ordering and caps at 50 (insert >50 or assert ordering across ≥2 listings with distinct `listed_at`) | `apps/core/test/stacks_web/listing_controller_test.exs` (or `marketplace_test.exs` for `list_active_listings/0`) |
| 2 | L1 US-7.1 sad | `POST /api/listings` returns 422 on duplicate active/draft listing for the same book+seller (`listings_active_book_seller_idx`) | `apps/core/test/stacks_web/listing_controller_test.exs` |
| 3 | L2 US-7.1 sad | 401 tests for `POST /api/listings`, `PUT /api/listings/:id/activate`, `/deactivate`, `/sold` | `apps/core/test/stacks_web/listing_controller_test.exs` or `controllers/unauthenticated_redirect_test.exs` |
| 4 | L2 US-7.1 sad (E2E) | Playwright: unauthenticated user at `/marketplace/create` sees login page (Issue §2 names create, not just mine) | `e2e/tests/marketplace.spec.ts` |
| 5 | L3 US-7.1 sad | Context-level unique-constraint test: second `create_listing/2` for same book+seller while first is draft/active returns changeset error | `apps/core/test/stacks/marketplace_test.exs` |
| 6 | L3 US-7.1 sad | Verify `:locked_listing` uses `SELECT FOR UPDATE` — concurrency test (two async transitions on one listing; exactly one wins) or a query-shape assertion on `lock_and_validate_transition` | `apps/core/test/stacks/marketplace_test.exs` |
| 7 | L4 US-7.1 happy | Extend the five "emits listing.* event" tests to assert payload `{ book_id, seller_id }`, not just `event_type` existence | `apps/core/test/stacks/marketplace_test.exs` |
| 8 | L4 US-7.1 sad | Negative emission tests: no `listing.activated` after `:invalid_transition`; no `listing.created` after `:no_placement` (Multi rollback ⇒ no event row) | `apps/core/test/stacks/marketplace_test.exs` |
| 9 | L5 US-7.1 happy | Assert `ListingExpiryJob` is registered in the Oban cron plugin config (`"0 1 * * *"`) | `apps/core/test/stacks/workers/listing_expiry_job_test.exs` |
| 10 | L5 US-7.1 sad | Per-listing failure isolation: one listing failing `expire_listing/1` doesn't abort the sweep of remaining expired listings | `apps/core/test/stacks/workers/listing_expiry_job_test.exs` |
| 11 | L9 US-7.1 sad | `accepted_values` test on `stg_listings.status` (draft/active/removed/expired/sold) — must go via proto manifest/`mix proto.sync` generator or a singular test (schema.yml is proto-generated; hand edits are overwritten) | `dbt/tests/singular/` or proto-sync generator |
| 12 | L9 US-7.1 sad | `relationships` tests: `stg_listings.book_id → stg_books.id`, `stg_listings.seller_id → stg_users.id` (same proto-sync caveat as #11) | `dbt/tests/singular/` or proto-sync generator |
| 13 | L10 US-7.1 happy | Elm state-machine tests for `Page.Marketplace.CreateListing`: init (`placements = Loading` + fires `Api.getMyPlacements`), `PlacementsReceived (Ok _)`, form Msgs (`PlacementSelected`/`ConditionSelected`/`PricingModeSelected`/`PriceChanged`/`ContactInfoChanged`/`DescriptionChanged`), `SubmitListing`, `ListingCreated (Ok _)`, `ActivateListing` → `ListingActivated (Ok _)` → OutMsg `NavigateTo Route.MarketplaceMyListings` | new `frontend/tests/Page/MarketplaceCreateListingTest.elm` (unit) and/or a program test alongside `UploadProgramTest.elm` |
| 14 | L10 US-7.1 sad | Elm failure-state tests: `PlacementsReceived (Err _)`, `ListingCreated (Err _)` error display, activate failure keeps draft, submit disabled without placement/contact, "no books to list" empty state | same new file(s) as #13 |
| 15 | L10 US-7.1 happy/sad (E2E) | Playwright create-listing flow (Issue §1): `/marketplace/create` → select book → all 5 condition radios → Fixed (ZAR input) vs Open-to-Offers → contact info → submit → "Listing Created" success view → Activate → navigated to `/marketplace/mine`; plus no-placements message, submit-disabled state, status-badge CSS classes, and error display on create/activate failure | `e2e/tests/marketplace.spec.ts` |
| 16 | L11 US-7.1 sad | Decide + implement: instrument ownership-verification-failure and unique-constraint-violation counts (Issue §12) and add telemetry firing tests (pattern: `upload_telemetry_test.exs`), or formally descope §12 and reclassify this cell n/a. **Partially blocked on feature implementation** — the counters do not exist in `marketplace.ex` yet. | `apps/core/lib/stacks/marketplace/marketplace.ex` + new telemetry test |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 1-US matrix (26 cells):

- **3 ✅ STRONG** — auth-guard happy path, database happy path, dbt happy path.
- **9 ⚠️ shallow** — strong core Elixir coverage undermined by specific
  enumerated gaps (index ordering/limit, mutation 401s, unique constraint,
  lock semantics, event payloads, cron registration, expiry failure
  isolation, Elm decoder-only coverage, missing metrics instrumentation).
- **3 ❌ missing** — event non-emission on rollback, dbt status/FK tests,
  Elm sad-path/state-machine tests.
- **11 n/a** — external services, storage (photos are future work), cache,
  performance (SLO gate), cost tracking (no external spend), operational
  metrics happy path (SLO gate + automatic telemetry).

**Headline findings:**
1. The feature is fully implemented server-side with genuinely good Elixir
   coverage (64 tests: full state machine, ownership, denormalization,
   expiry job) — but the two mechanisms Issue #120 calls out by name,
   `SELECT FOR UPDATE` locking and the `listings_active_book_seller_idx`
   unique constraint, have **zero** tests.
2. The Elm frontend has **no marketplace page tests at all** (only proto
   decoder round-trips), and Playwright covers browse/detail/mine but not
   the create-listing flow — the primary UI journey of US-7.1 is untested
   end to end.
3. All five listing events are emission-tested but only for existence —
   payload shape and rollback non-emission are unverified.

**Test runner totals at baseline:** Elixir 64 marketplace-related tests
(4 files), Elm 7 listing decoder tests, Playwright 8 marketplace tests,
dbt 6 generic column tests on the two listing models. Punch list: **16
items**, of which 1 (#16) is partially blocked on instrumentation code.
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires marketplace context, listing controller, listing expiry job.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
