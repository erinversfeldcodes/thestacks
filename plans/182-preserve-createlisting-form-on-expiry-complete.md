# Issue #182 — Complete

**Issue**: #182 — Preserve an in-progress CreateListing when the session expires mid-compose (US-14.3.2)
**Branch**: `182-preserve-createlisting-form-on-expiry` (off `feat/124-e2e-auth`)
**Completed**: 2026-07-11
**Agents**: elm-agent (P1 + P2b), elixir-agent (P2a) · **Revision cycles**: 1 (P1 ux) + a test-mechanism fix
**Scope**: EXPANDED mid-issue (user-approved) to fold in a pre-existing P1 bug the live E2E uncovered.

## What shipped

### Part 1 — Draft persistence (the original feature)
A session revoked while composing a marketplace listing no longer discards the form. On a submit-time
401, CreateListing emits `SessionExpiredWithDraft` → `Main` persists the draft to localStorage (key
`stacks-listing-draft`, separate from `stacks-auth` so `clearAuth` doesn't wipe it) then redirects to
`/login` with a "your listing draft is saved" notice. On return to `/marketplace/create` the form
rehydrates field-for-field (re-selecting the book), with a styled restored-draft banner + a Discard
control. Draft cleared on successful submit, discard, and **explicit logout** (defense-in-depth so the
`contactInfo` PII never lingers). **Cross-user guard**: the draft is stamped with the composing user's
id and only rehydrates on a match — a foreign/corrupt draft is cleared, never shown.

### Part 2 — Repaired the CreateListing sell-flow (pre-existing P1, folded in)
The live E2E revealed the "Create Listing" UI never worked: the form sent `placement_id` (always empty
— `/api/placements/mine` returned no id) while `Marketplace.create_listing` reads `book_id`; the
dropdown showed every book as "Untitled" (summary had no title). Fixed by aligning the whole chain on
`book_id`:
- **proto (additive, `buf breaking` clean)**: `CreateListingRequest` gains `book_id=7` (`placement_id=1`
  kept + deprecated); `PlacementSummary` gains `title=3`.
- **backend**: `get_user_placements_summary` joins books → returns `title`.
- **frontend**: `/api/placements/mine` decodes to a `Placement` carrying real `book_id`+`title`; the
  option value is the book id; the form threads `book_id` end-to-end.

## Gate record
- 2A: P1 elm-reviewer **APPROVE** (cross-user guard signed off) + ux **SHIP** after the banner-CSS
  revision. P2 contract/integration reviewer **APPROVE — "the chain connects: YES"** across all 5 hops.
- 2B-i `just verify`: **exit 0** (both before and after Phase 2 — full suite incl. proto.sync --check,
  buf lint/breaking).
- 2B-ii: 612 elm tests; backend summary-title RED→GREEN; Elm codec/guard/non-vacuity tests.
- 2B-iia: no migration (proto additions are API DTOs; `mix proto.sync` idempotent, zero churn).
- **2B-iii Deploy-Preview + E2E: PASS** — clean run **182 passed** (all marketplace/catalogue/bookshelf
  green, proving the `book_id` fix live), and the **`marketplace-draft` round-trip PASSES** (26.3s):
  fill (real book selection) → server-side revoke → submit 401 → draft persisted + redirect with the
  draft-saved notice → re-login → **form restored field-for-field** → discard clears.
- 2F PE: folded into the integration review (cross-user guard + book_id chain confirmed; backend inner
  join safe — `book_id` is a NOT-NULL FK under the ISBN hard gate).

## Notable engineering findings (for the retro)
1. **The live E2E earned its keep — it caught a real, pre-existing, user-facing P1** (the entire sell
   flow was broken) that unit tests + the marketplace E2E missed (the latter bypasses the UI, POSTing
   `book_id` directly). Validation-by-real-user-behaviour is exactly why we do it.
2. **E2E 401-trigger mechanism**: poisoning `localStorage` only expires the session on the *next
   reload* (the SPA holds the token in memory). For an **in-session** authed action (a submit with no
   reload), you must **revoke server-side** (`DELETE /api/auth/logout`, guardian_db #124 A2). This is
   also the realistic #182 scenario ("logged out elsewhere mid-compose").
3. A network interruption mid-run produced 19 cross-spec failures (`ERR_INTERNET_DISCONNECTED`);
   distinguishing that from a real regression required reading the errors, not the pass/fail count.
4. The recon repeatedly mis-identified the JS port host as the stale standalone `frontend/index.html`;
   the real esbuild glue is `apps/core/assets/js/app.js` (served by Phoenix). Recorded so future recon
   checks the served build.

## Files (16; generated `proto/gen/` excluded — regenerated at build time)
proto: `requests.proto`, `placement.proto` · backend: `shelving.ex`, `bookshelf_placement_controller_test.exs`
· JS: `apps/core/assets/js/app.js` · Elm: `Main.elm`, `Api.elm`, `Types/Placement.elm`,
`Page/Marketplace/CreateListing.elm`, `Page/Login.elm`, `css/main.css` · Elm tests:
`CreateListingDraftTest.elm`, `PlacementDecoder.elm`, `LoginTest.elm`, `LoginRedesignTest.elm` · E2E:
`marketplace-draft.spec.ts`.

## Batch
Follow-up #3 of #178–182 complete (order 181 → 178 → 182 → 179 → 180, per-issue gates). Next: **#179**.
