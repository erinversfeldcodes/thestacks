# Plan: Extend the session-expiry 401 interceptor to the remaining authed pages
**Issue**: #178  ·  **Created**: 2026-07-11  ·  **Status**: Awaiting approval

## Context
#173 shipped `Main.sessionExpired` + `Api.isUnauthorized` + silent renewal, covering the 8 authed
pages that already had an `OutMsg` channel. 11 authed pages are still 2-tuple `update`s whose
`Http.BadStatus 401` is swallowed → on those pages a revoked/expired session leaves a broken view
instead of redirecting to `/login`. This converts them to the proven 3-tuple `OutMsg` +
`SessionExpired` pattern and closes the boot-time gap for free.

## Research Summary (topology map — grounded, not estimated)
- **Template**: `Page/Upload.elm` — `type OutMsg = NoOut | … | SessionExpired` (L92-96); emission idiom
  `if Api.isUnauthorized err then ( model, Cmd.none, SessionExpired ) else ( …, NoOut )` (L185-190);
  `Main.update` destructures the 3-tuple and routes `Upload.SessionExpired -> sessionExpired model`
  (Main.elm L1032/L1045-46). `Groups.elm` is a second reference.
- **Shared parts (reuse, do not re-add)**: `Main.sessionExpired` (Main.elm:563), `Api.isUnauthorized`
  (Api.elm:345 — 401 only; 403 stays local).
- **All 11 pages** are currently 2-tuple, no `OutMsg`, each with ≥1 token-required 401-capable request:
  | Page | authed recv-Msg(s) | Main wiring |
  |---|---|---|
  | Admin/Metrics | DashboardReceived / QualityTrendsReceived / SourceHealthReceived / EnrichmentGapsReceived | `AdminMetricsMsg` L1375 |
  | Admin/ScraperConfig | SourceHealthReceived | `AdminScraperConfigMsg` L1361 |
  | Admin/SourceApproval | SourcesReceived / ApproveCompleted / RejectCompleted | `AdminSourceApprovalMsg` L1344 |
  | Blog/Post | AssociationActionCompleted / CommentSubmitted / CommentDeleted (token writes); PostLoaded/CommentsLoaded optional-auth | `BlogPostMsg` L1327 |
  | Blog/Editor | SaveCompleted / PublishCompleted | `BlogEditorMsg` L1310 |
  | Marketplace/MyListings | ListingsReceived / ListingUpdated | `MyListingsMsg` L1248 |
  | Catalogue | UserPlacementsLoaded / PlaceBookCompleted (authed). `CatalogueReceived` is PUBLIC — leave local | `CatalogueMsg` L1183 |
  | Search | SearchCompleted | `SearchMsg` L1067 |
  | Settings/AgeVerification | SaveCompleted | `AgeVerificationMsg` L1101 |
  | Settings/Consent | SaveCompleted | `ConsentMsg` L1084 |
  | Settings/Privacy | SaveProfileVisibilityCompleted / SaveShelfVisibilityCompleted | `PrivacyMsg` L1279 |
- **Boot-time free win**: `GotPlacementCheck (Err _) -> ( model, Cmd.none )` (Main.elm:1588-89) swallows
  a 401 on every boot/reload for ALL pages. Wiring it to `sessionExpired` closes boot/reload expiry
  coverage universally — no OutMsg conversion. Highest value / lowest cost item.

## Approach & scope decisions
- **Convert only the authed `Err` branches.** Public/optional-auth reads that legitimately succeed
  without a token stay local: Catalogue's `getCatalogue` list fetch (never sends auth) stays `NoOut`.
  Blog optional-auth reads (`getBlogPost`/`getPostComments`) — route their 401 too (a logged-in user
  with an expired token sends it and gets 401), consistent with #173's judgment; the token-required
  writes are the primary driver.
- **Preserve #173's local exclusions**: 403 age-gate local; login/register local; no change to
  Upload SSE / BookDetail availability mid-pipeline flows (not in this set anyway).
- **Each page keeps existing behaviour; only the 401 path changes** (RED proves a 401 → `SessionExpired`
  not `NoOut`; a 403/success → unchanged local handling).

## Phases (split to keep each agent pass focused + reviews digestible — #173 retro: an 11-page
single pass is too big)
### Phase 1 — boot hook + Settings + Admin (elm-agent)
1. **Boot hook (do first)**: `Main.elm` `GotPlacementCheck (Err err)` → `if Api.isUnauthorized err then sessionExpired model else ( model, Cmd.none )`. Unit-test the routing at the Main seam if reachable; else cover via the Phase-2 E2E + a note.
2. Convert **Settings/AgeVerification, Settings/Consent, Settings/Privacy** and **Admin/Metrics,
   Admin/ScraperConfig, Admin/SourceApproval** (6 pages) to `OutMsg` + `SessionExpired`; wire each in
   `Main.update`.
3. Page-seam unit test per page: a 401 in an authed `Err` branch yields `SessionExpired`; a 403/success stays local (`NoOut`).
**DoD**: 6 pages + boot hook routed; per-page RED→GREEN; `elm-test` + `elm-review` green for the batch.

### Phase 2 — Blog + Marketplace + Discovery (elm-agent)
1. Convert **Blog/Post, Blog/Editor, Marketplace/MyListings, Catalogue, Search** (5 pages), same pattern.
   Catalogue: route only the authed branches (`UserPlacementsLoaded`, `PlaceBookCompleted`); leave the
   public `CatalogueReceived` local.
2. Page-seam unit test per page (same shape).
**DoD**: 5 pages routed; per-page RED→GREEN; `elm-test` + `elm-review` green.

## Gate Plan (issue-level, after both phases)
- 2A-iv reception: DoD Evidence Table + testing-coordinator (non-vacuity of the page-seam tests).
- 2B-i `just verify` (elm + full suite). 2B-ii spec coverage (11 pages + boot hook all routed).
- 2B-iia **skip** (no migration/DB).
- **2B-iii Deploy-Preview + E2E**: REQUIRED by DoD — extend `e2e/tests/auth.spec.ts` to prove the
  redirect from a previously-uncovered page (proposed: **Settings/Privacy** — stable, authed, easy to
  drive; revoke/expire mid-session → assert redirect to `/login` with the notice). Deploy to Fly
  preview + run E2E.
- 2C: **elm-reviewer** (idiom + no behaviour drift) + **ux-reviewer** (light — the redirect experience
  is unchanged from #173; confirm no regressions). No contract change (no proto/endpoint) → no
  contract-reviewer.
- 2F Principal Engineer: light — confirm the residual gap is now in-session-on-uncovered-page only
  (shrunk by the boot hook) and nothing bypasses the backend `:authenticated` gate.

## Dependencies
#173 (interceptor mechanism). Agent: elm-agent. Same epic branch (`feat/124-e2e-auth`).
