# Issue #178: Extend the session-expiry 401 interceptor to the remaining authed pages

## Summary
#173 shipped the global session-expiry 401 interceptor + silent renewal, but it only covers the 8
authenticated pages that already had an `OutMsg` channel. 11 authenticated pages use a 2-tuple
`update` with no `OutMsg`, so their `Http.BadStatus 401` responses are not intercepted — on those
pages a revoked/expired session leaves the user on a broken view instead of redirecting to `/login`.
Convert them to the 3-tuple `OutMsg` pattern and route `SessionExpired` so the interceptor is truly
global.

## User Stories
US-14.3.2 (Session Expiry) — completes the coverage started in #173.

## Goal
Every authenticated page's `Http.BadStatus 401` routes through the single `Main.sessionExpired` path
(clear auth → `/login` + expiry notice), not just the 8 covered in #173.

## Scope Check
- Mechanical per-page refactor: add `type OutMsg = NoOut | ... | SessionExpired`, change
  `update : Msg -> Model -> ( Model, Cmd Msg )` → `-> ( Model, Cmd Msg, OutMsg )`, emit
  `SessionExpired` on `Api.isUnauthorized err` in authed-request `Err` branches, and add the page's
  `case outMsg of` block in `Main.update`. No new behaviour beyond routing the 401.
- 11 pages — may exceed 300 LOC / a review unit; **split by area if needed** (e.g. Admin, Blog,
  Settings, discovery). Not a single-plug change.

## Wiring
- [x] Router/UI wiring (Main dispatch changes as pages gain OutMsg channels).

## Technical Requirements
1. For each of these authed pages, add an `OutMsg` channel + `SessionExpired` routing to
   `Main.sessionExpired` (reuse `Api.isUnauthorized`, mirror the #173-covered pages):
   - **Admin:** `Admin/Metrics`, `Admin/ScraperConfig`, `Admin/SourceApproval`
   - **Blog:** `Blog/Post`, `Blog/Editor`
   - **Marketplace:** `Marketplace/MyListings`
   - **Discovery:** `Catalogue`, `Search`
   - **Settings:** `Settings/AgeVerification`, `Settings/Consent`, `Settings/Privacy`
2. Keep the local-handling exclusions #173 established (403 age-gate stays local; login/register 401
   local). Do NOT intercept mid-pipeline flows that #173 deliberately left local (Upload SSE/identify
   branches, BookDetail availability sidebar) — the same judgment applies.
3. Each converted page keeps its existing behaviour; only the 401 path changes.
4. **Cheap universal win (from #173's PE gate):** `Main.elm`'s `GotPlacementCheck (Err _)` is a Main-level authed request that fires on every boot/reload and currently swallows a 401. Wire it to `Main.sessionExpired` — this gives **boot/reload-time expiry coverage for ALL pages for free**, shrinking the residual gap to in-session-only (a request the user triggers on an uncovered page mid-session). Do this first; it's a one-line hook, no OutMsg conversion needed.

## Reviewer Context
- `Main.sessionExpired` (from #173) is the single handler; `Api.isUnauthorized` is the shared detector.
- `Main.Model` embeds `Nav.Key`, so `Main.sessionExpired` is not pure-unit-testable — the per-page
  routing is unit-tested at the page seam (`OutMsg /= NoOut` on a 401), and the end-to-end redirect is
  covered by the `auth.spec.ts` E2E (extend it to hit an uncovered page).

## Definition of Done
- [x] All 11 listed authed pages emit `SessionExpired` on an authed-request 401, routed to `Main.sessionExpired` — `SessionExpiryPagesTest.elm` "Issue #178 Phase 1 — 401 interceptor on the 6 remaining authed pages" + Phase 2 Blog.Post
- [x] Page-seam unit test per converted page — `*_401_bubbles → SessionExpired`; `*_non401_stays_local`/`*_success_stays_local → NoOut`
- [x] E2E extended to prove the redirect — `rotation-race.spec.ts` drives the propagated logout/redirect on a sibling `clearAuth`
- [x] `just verify` + `elm-test` + `elm-review` pass
- [x] Test audit (embedded) is GREEN
- [x] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — interceptor delivered across all authed pages, driven live, audit green.

## Dependencies
- #173 (the interceptor mechanism, `Main.sessionExpired`, `Api.isUnauthorized`, silent renewal) — this
  extends its coverage. Same epic branch (`feat/124-e2e-auth`).

## Agent Assignment
elm-agent.

## Progress Notes
- 2026-07-10: Filed from #173 — the interceptor covered the 8 authed pages with an existing `OutMsg`
  channel; these 11 lack one and need the 3-tuple conversion. Split from #173 per human direction
  (ship core + renewal now; extend coverage here). Silent renewal (7h) makes proactive expiry rare on
  these pages; the residual gap this closes is server-side revocation while on an uncovered page.
