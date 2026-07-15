# Issue #213: Profile read endpoints — `GET /api/u/:handle` + `…/bookshelves/:name`

## Summary
The backend read surface for public profiles: one controller (`ProfileController`) with two
`optional_auth` endpoints — the profile hub (`GET /api/u/:handle`, redacted profile +
viewer-visible shelves) and the shelf browse (`GET /api/u/:handle/bookshelves/:bookshelf_name`,
placement-filtered). Ghost/block gate is single-sourced through `Visibility.profile_visible?/2`
and returns **404, never 403**. Reuses the visibility resolver with zero enforcement changes.

## User Stories
- **US-10.5.2** — View a Reader's Public Profile (`docs/user_stories/US-10.5.2-view-profile.md`) — the hub endpoint.
- **US-10.5.3** — Browse a Reader's Bookshelf (`docs/user_stories/US-10.5.3-browse-library.md`) — the shelf endpoint (backend half; Elm read-only view is #215).

## Goal
Two endpoints that resolve the viewer from optional auth, gate ghost/blocked/unknown → 404,
redact the profile payload, and filter shelves + placements through
`viewable_shelves/2` / `shelf_with_placements/2` — so the visibility matrix is enforced
at the reader-facing surface.

## Scope Check
- >3 controllers? No — one new (`ProfileController`).
- >2 new endpoints? No — exactly two (`show`, `shelf`).
- >~300 LOC? No.
- Combines unrelated concerns? No — both endpoints share the ghost gate + redacted serializer.

## Wiring
- [x] Router wiring included (`apps/core/lib/core_web/router.ex:127-128`, `optional_auth` scope). API-only; the SPA hub/browse pages are #214/#215.
- [ ] Implementation only.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.5.2 — View a Reader's Profile | route `get "/u/:handle"` (`router.ex:127`) → `ProfileController.show` (`apps/core/lib/stacks_web/controllers/profile_controller.ex:24`) → `profile_visible?/2` gate (`visibility.ex:329`) → `viewable_shelves/2` → `ProtoJSON.public_profile/2` (`proto_json.ex:577`, redacted) | ✅ verified — `profile_controller_test.exs:24` redacted 200; `:56` ghost→404; `:82` blocked→404; `:75` unauthenticated 200 | ✅ | built end-to-end (backend) |
| US-10.5.3 — Browse a Reader's Bookshelf (backend) | route `get "/u/:handle/bookshelves/:bookshelf_name"` (`router.ex:128`) → `ProfileController.shelf` (`profile_controller.ex:32`) → ghost gate + `resolve_visibility(bookshelf, viewer)` → `shelf_with_placements(&1, viewer)` | ✅ verified — `profile_controller_test.exs:92` platform placement shown / owner-only filtered (`count == 1`); `:123` bad name→404; `:133` ghost shelf→404 | ✅ | backend built; the Elm read-only render is #215 |

Verdict: ✅ implemented (backend) — both endpoints built end-to-end and driven by controller tests through the real (viewer, target) pairs.

## Technical Requirements
- `ProfileController.show/2`: `get_user_by_handle` → 404 if none; `profile_visible?/2` → 404 if ghost/blocked; else `public_profile(target, viewable_shelves(target.id, viewer))`.
- `ProfileController.shelf/2`: validate bookshelf name (404 otherwise); ghost gate; `resolve_visibility(bookshelf, viewer)` → 404 if hidden; else map `get_bookshelf_shelves(target.id, name)` through `shelf_with_placements(&1, viewer)`; `count` reflects visible placements only.
- `Visibility.profile_visible?/2` — the single-sourced ceiling rule (owner=ghost → hidden to non-owner; `{:platform_user, id}` and `:unauthenticated` clauses).
- `ProtoJSON.public_profile/2` — redacted shape (`handle, display_name, website_url, city, country_code, bookshelves[].name`), never email/consent/role/prefs.
- Viewer derived from `optional_auth` (`Guardian.Plug.LoadResource, allow_blank: true`): `{:platform_user, id}` | `:unauthenticated`.

## Reviewer Context
- **404, not 403** is a deliberate security choice — a ghost/blocked profile must be indistinguishable from a non-existent one (mirrors the block-404 rule).
- The endpoints must **not** re-implement visibility — they wire `(viewer, target)` into the already-tested resolver. Tests assert the wiring, not the combinatorics.
- `optional_auth` means these work signed-in or out; the viewer identity only changes *what* is returned, never *whether* the request is allowed.
- `insert(:placement, bookshelf:, shelf:, …)` factory — not `shelf:` as the container key for the bookshelf (see project memory: `:placement` takes `bookshelf:`).

## Test Audit
FULL 13-layer × 2 US (10.5.2 hub, 10.5.3 shelf), happy/sad columns. The sad columns
carry the **visibility matrix** assertions. Legend: ✅ real | ⚠️ shallow | ❌ missing | n/a.

**Framework-layer summary**

| Layer | 10.5.2 | 10.5.3 |
|-------|--------|--------|
| Elixir (controller) | ✅ | ✅ (platform/owner) |
| Elm | n/a (→#214) | n/a (→#215) |
| E2E | ❌ (→ dissolved from #218 into #214/#215) | ❌ (→#215) |

**Existing test inventory (verified by read):** `apps/core/test/stacks_web/controllers/profile_controller_test.exs` — 10 tests (7 hub + 3 shelf), listed per cell below. Resolver combinatorics are covered upstream in `apps/core/test/stacks/visibility_test.exs` (40 tests incl. group-membership + age-gate + marketplace) — not re-proven here.

#### Layer 1: API Calls

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.2 | ✅ `profile_controller_test.exs:24` "returns a discoverable user's redacted public profile" (200 + fields); `:75` "an unauthenticated viewer can see a discoverable profile" | ✅ | ✅ (matrix) `:56` ghost→404, `:70` unknown handle→404, `:82` blocked viewer→404 | ✅ |
| 10.5.3 | ✅ `:92` "returns only the placements the viewer may see" (platform shown, owner-only filtered, `count == 1`) | ✅ | ✅ (matrix) `:123` invalid name→404, `:133` ghost shelf→404 | ✅ |

#### Layer 2: Auth & Middleware Guards

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.2 | ✅ `:24`/`:42` authenticated viewer via `auth_conn`; `:75` unauthenticated path (`optional_auth`, allow_blank) | ✅ | ✅ (SECURITY) `:56` ghost→404, `:82` blocked→404, `:63` owner-sees-own-ghost (positive-boundary) | ✅ |
| 10.5.3 | ✅ `:92` authenticated viewer; ghost gate applied before shelf load | ✅ | ✅ (SECURITY) `:133` ghost shelf→404. ❌ **no unauthenticated-viewer case at the shelf endpoint** (hub has `:75`; shelf does not). → **punch #1** | ⚠️ |

#### Layer 3: Database Interactions

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.2 | ✅ `get_user_by_handle` + `viewable_shelves` exercised by `:24`/`:42`; `:42` proves the owner-visibility shelf is DB-filtered out | ✅ | ✅ `:70` unknown handle (no row)→404 | ✅ |
| 10.5.3 | ✅ `:92` `get_bookshelf_shelves` + per-placement resolve; `count` reflects DB-filtered set | ✅ | ✅ `:123` unknown bookshelf name→404 | ✅ |

#### Layer 4: Event Flow & Lifecycle
All cells **n/a** — US-10.5.2 §6 / US-10.5.3 §6: a profile/shelf read emits no events.

#### Layer 5: Background Jobs (Oban)
All cells **n/a** — US §7: no jobs on the read path.

#### Layer 6: External Service Calls
All cells **n/a** — US §8: no external calls (cover images are already-stored URLs).

#### Layer 7: Storage (R2 / Local)
All cells **n/a** — US §9: no new storage; cover URLs served as-is.

#### Layer 8: Cache Interactions
All cells **n/a** — US §10: direct DB reads through the resolver, no cache layer.

#### Layer 9: dbt Model Dependencies
All cells **n/a** — US §11: read path, no dbt dependency.

#### Layer 10: Elm Frontend State Machine
**n/a here** — the hub state machine is #214 (`Page.Profile`), the read-only browse is #215 (`Page.Bookshelf`). This issue is the backend surface only.

#### Layer 11: Operational Metrics
All cells **n/a — covered by SLO gate.** US-10.5.2 §13 explicitly defers `profile_view` (and warns: never tag by handle — unbounded cardinality). `scripts/check-slo-gate.sh` covers per-route SLIs.

#### Layer 12: Performance & Usability
All cells **n/a — SLO gate.**

#### Layer 13: Cost Tracking
All cells **n/a — Neon reads only** (US §15); no per-call spend.

### Punch list
1. ✅ **DONE** — L2 10.5.3 unauthenticated shelf: `profile_controller_test.exs` "an unauthenticated viewer sees platform placements but not owner-only ones (shelf)".
2. ✅ **DONE** — group-visible shelf + placement: "a group-visibility shelf shows to a member and hides from a non-member (hub)" + "…placement…(shelf)".
3. ✅ **DONE (feature)** — age-gating turned out to be a genuine **feature gap**, not just a missing test: `resolve_visibility(%Placement{})` ran `check_age_gate` on the placement, which has no `visibility_tier`, so an age-gated book's spine was shown when browsing a shelf. Fixed in `visibility.ex` — a placement now inherits its book's age gate (hidden from an unverified non-owner; owner always sees own; book-level age gate unchanged). Tests: "an age-gated book is hidden from unverified/unauthenticated viewers, shown to verified" + "the owner sees their own age-gated book even when unverified".
4. ⬜ **E2E** — a browser drive of hub + shelf across viewer perspectives. Dissolved from the old #218 into #214 (hub) / #215 (shelf) live-drives + `e2e/tests/public-profile.spec.ts`.

### Verdict
**GREEN (backend) — the full visibility matrix is now asserted on these endpoints.**
Redaction, ghost→404, blocked→404, unknown→404, owner-sees-own-ghost, platform-shown /
owner-filtered, bad-name→404, **group member-vs-non-member (hub + shelf)**, **unauthenticated
shelf**, and **age-gate (hidden from unverified non-owner; owner sees own)** are all real ✅.
The age-gate row exposed a genuine feature gap (placements didn't inherit the book's age gate),
now fixed in `visibility.ex`. The only remaining item is the browser E2E live-drive, owned by
#214/#215 (a dissolved-#218 line, not a backend gap).

## Definition of Done
- [x] `ProfileController.{show,shelf}` + routes + `profile_visible?/2` + `public_profile/2`.
- [x] 10 controller tests (redaction, ghost/blocked/unknown → 404, owner-sees-own, shelf placement filtering).
- [x] Punch items 1–3 closed — unauthenticated-shelf, group-visibility, and age-gate (feature + assertions).
- [x] `visibility.ex` placement age-gate feature (a placement inherits its book's age gate; owner-exempt; book-level gate unchanged) — verified no regression (`visibility_test`/property/`bookshelf_controller_test` green).
- [ ] **Feature-Completeness Pre-Check ✅** — both endpoints live-driven (via #214/#215 browser E2E).
- [ ] `just run just verify` passes.
- [x] **Test audit (above) is GREEN (backend)** — 0 ❌ on the controller/resolver matrix; the remaining ❌ is the browser E2E, owned by #214/#215.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — pending the live-drive.

## Dependencies
#211 (handle lookup). The visibility resolver + `Social` blocking (pre-existing).

## Agent Assignment
elixir-agent (endpoints + punch assertions) → testing-agent (matrix variations).

## Progress Notes
Landed on `feat/210-public-profiles`: controller, routes, `profile_visible?/2`, `public_profile/2`, 10 tests. Group-visibility + age-gate + unauthenticated-shelf assertions outstanding.
