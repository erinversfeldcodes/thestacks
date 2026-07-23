# Issue #276: Enforce the 50-Item Reading Pile Limit (Currently a View-Layer Illusion)

## Summary
The product intent is a **hard limit of 50 books in progress** on the Reading Pile. That limit is
**not implemented**. The only thing resembling it is `List.take 50 placements` in the Elm view
(`frontend/src/Page/Bookshelf/ReadingPile.elm:156`), which silently truncates the render.

Nothing prevents a 51st placement:
- `Shelving.place_book/3` (`apps/core/lib/stacks/shelving.ex:192`) — no cap
- `Shelving.move_book/3` (`apps/core/lib/stacks/shelving.ex:242`) — no cap
- No DB constraint (`20260305000005_create_bookshelves.exs` defines the enum only)
- No controller-level validation in `BookshelfPlacementController`

**Current behaviour:** a user can move 60 books to their reading pile. The API accepts all 60, the
database stores all 60, `GET /api/bookshelves/reading_pile` returns all 60 — and the UI renders 50,
silently hiding 10 with no count, no pagination, and no message. The user's books are present and
invisible.

Discovered during Issue #112's planning gates.

## User Stories
- US-1.2.4 — Browse the Reading Pile (the surface where the truncation is visible)
- US-1.6.x — moving books between bookshelves (the write path that must enforce the limit)

## Goal
The 50-item limit is a real constraint, enforced at the write path, with a clear user-facing message
when it is reached — and no book is ever silently invisible.

## Scope Check
- Does this issue touch more than 3 controllers? No — `BookshelfPlacementController` only.
- Does this issue add more than 2 new endpoints? No — no new endpoints.
- Does this issue exceed ~300 lines of production code? No.
- Does this issue combine unrelated concerns? No — one constraint, its enforcement, and its surfacing.

## Wiring
Router wiring: includes wiring — user-facing on completion (a user attempting a 51st placement sees a
clear message instead of silent truncation).

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.2.4 — Reading Pile respects a 50-item limit | `ReadingPile.elm:156` truncates view only; no enforcement at `shelving.ex:192`/`:242`, no DB constraint, no controller validation | Not driven — enforcement does not exist to drive | ❌ missing | **Build in-scope** (this issue) |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### Enforcement (write path)
- Reject a placement that would make the reading pile exceed 50, in **both**
  `Shelving.place_book/3` and `Shelving.move_book/3` — `move_book` is the likelier real-world route
  (antilibrary → reading_pile) and must not be overlooked.
- Return a domain error the controller maps to a clear HTTP response (a 422 with a specific error
  code, consistent with existing placement error handling — do not invent a new convention).
- The limit applies to **reading_pile only**. Other bookshelves stay unbounded. Define the constant
  once, in the context — not duplicated in the view.
- Consider the race: two concurrent placements could each see 50 and both succeed. Decide whether a
  DB-level constraint or a transaction guard is warranted, and record the decision. A partial-index or
  count-check-in-transaction is likely sufficient; state the reasoning rather than leaving it implicit.

### Existing data — decide before implementing
Some users may **already** exceed 50 (nothing has prevented it). Enforcement must not corrupt or
discard their data. Pick and document one:
- **Grandfather** — existing over-limit piles are permitted, but no *new* placements until they drop
  below 50. (Recommended: no data loss, converges naturally.)
- **Surface** — show the true count and let them choose what to remove.
- **Never**: silently delete or hide the excess. That is the current bug, not the fix.
Check whether any user actually exceeds 50 before deciding; the answer may make this trivial.

### Frontend
- Surface the rejection meaningfully on the write path (e.g. "Your reading pile is full — finish or
  remove a book before adding another"). Wording to match the project's voice; the empty-state strings
  in `issues/112-e2e-shelf-browsing.md:104-108` are the tonal reference.
- Re-evaluate `List.take 50` (`ReadingPile.elm:156`). Once the write path is enforced it becomes
  defensive rather than load-bearing. **Keep or remove deliberately** — if kept, it must never be the
  only thing standing between a user and invisible books.

## Reviewer Context
- `ReadingPile` is a **separate routed module** from the unified `Page.Bookshelf`, with its own Msg
  and model: `BooksLoaded` + `books : RemoteData Http.Error (List Placement)` (`ReadingPile.elm:41`,
  `:27`). Do not assume the unified page's `ShelvesLoaded`/`shelves` shape.
- The pile flattens server shelves via `List.concatMap .placements shelves` (`ReadingPile.elm:70`),
  so the 50 count is over **flattened placements**, not shelves.
- `@valid_bookshelf_names` is at `shelving.ex:26`.
- Placement mutations emit events (`placement.created`, `placement.moved`) — a rejected placement must
  **not** emit one. Assert this; a spurious event would corrupt the warehouse aggregates.

## Test Audit
Compact format — focused feature issue.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| API (L1) | yes | ❌ → ✅ — 51st placement via `place_book` **and** via `move_book` returns the documented error; 50th succeeds (boundary asserted both sides) |
| DB (L3) | yes | ❌ → ✅ — pile never exceeds 50; concurrent-placement behaviour matches the documented decision |
| Event flow (L4) | yes | ❌ → ✅ — a **rejected** placement emits no `placement.created`/`placement.moved` event |
| Elm state machine (L10) | yes | ❌ → ✅ — the rejection error renders a user-facing message; pile view behaviour at exactly 50 asserted |
| E2E (browser) | yes | ❌ → ✅ — user with a full pile attempts to add and sees the message (real path, no mock) |
| 2, 5–9, 11–13 | no | n/a — no auth, job, external service, storage, cache, dbt, metric or cost surface changed |

## GDPR
n/a — stated as a positive finding. This adds a count constraint on existing placement rows. No new
personal-data column, no new user-data endpoint, no event-payload field, no dbt model. Erasure and
export reachability are unchanged.

## Definition of Done
- [x] Limit enforced in `Shelving.place_book/3` — evidence: "place_book/3 rejects the 51st reading_pile placement" (+ 50th-succeeds), shelving_test.exs, green through the 2855/0 suite
- [x] Limit enforced in `Shelving.move_book/3` — evidence: "move_book/3 rejects a move that would make 51" (+ exactly-50 allowed), shelving_test.exs
- [x] Boundary asserted both sides (50th succeeds, 51st rejected) — evidence: the four boundary tests above (both ops, both sides)
- [x] Rejected placement emits **no** event — evidence: "rejected place_book writes no placement, event, or audit row" + move variant (also assert history absence)
- [x] Concurrency decision documented and its behaviour tested — evidence: SELECT ... FOR UPDATE serialisation comment in shelving.ex capacity check + "two concurrent placements cannot exceed the cap" test
- [x] Existing over-limit users handled per the documented choice (grandfather), with **no data loss** — evidence: dev-DB survey 2026-07-22 (largest pile 4, nobody grandfathered) + 55-book grandfather test (keeps all, rejects adds, allows moves out)
- [x] User-facing message shown on rejection — evidence: live browser drives with screenshots on BOTH paths — move (reading-pile-limit.spec green locally + preview) and direct-place (#281 catalogue picker drive, screenshot delivered 2026-07-23)
- [x] `List.take 50` removed deliberately, with reasoning recorded — evidence: ReadingPile.elm comment (truncation would hide grandfathered books) + grandfathered-renders-everything elm test
- [x] **Feature-Completeness Pre-Check (above) is ✅** — evidence: enforcement built at the write path and observed live (API 422 + browser message, local + preview)
- [x] Every behaviour has a validation path — evidence: L1/L3/L4/L10/E2E rows all covered per the audit table (updated below)
- [x] `just verify` passes — evidence: full gate green at land (2026-07-22) and every subsequent fresh-DB/ci gate through 2026-07-23

## Dependencies
- Related: **#112** (E2E Shelf Browsing) writes Reading Pile tests. Coordinate: #112 asserts the view
  renders **at most** 50 (true before and after this issue) and must **not** encode the current
  silent-truncation behaviour as expected. This issue owns the enforcement assertions.
- Not an #112 epic child — #112 is test coverage for browsing; this is a feature build. Blocking
  #112's PR on it would be scope creep.

## Agent Assignment
`elixir-agent` (context + controller), `elm-agent` (error surfacing).
Reviewers: `elixir-reviewer` + `contract-reviewer` (error shape crosses the API boundary).

## Progress Notes
[Updated by agents during execution.]
