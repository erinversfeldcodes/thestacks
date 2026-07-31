# Plan: Preserve an in-progress CreateListing when the session expires mid-compose
**Issue**: #182  ·  **Created**: 2026-07-11  ·  **Status**: Awaiting approval

## Context
CreateListing is already #173-covered: a 401 on submit (`ListingCreated`) routes `SessionExpired ->
Main.sessionExpired`, which clears auth and redirects to `/login`. The gap: the in-progress form is
**silently discarded** on that redirect (re-init on route gives a fresh empty page). This is the
worst-case interruption — the only covered page with substantial unsaved input.

## Research Summary (grounded)
- **Form state to preserve** (`Page/Marketplace/CreateListing.elm:30-40`) — 5 user-input fields:
  `selectedPlacementId, condition, pricingMode, priceInput, contactInfo, description`. `placements` is
  re-fetched by `init` from the token (don't persist; but `selectedPlacementId` must survive to
  re-select after the re-fetch).
- **Already 3-tuple** with `type OutMsg = NoOut | NavigateTo Route | SessionExpired` (L57-60);
  `update … Maybe String -> ( Model, Cmd Msg, OutMsg )` (L88). The submit 401 branch is
  `ListingCreated (Err …)` at L161-162.
- **`Main.sessionExpired`** (Main.elm:563-575) clears auth, fires `clearAuth ()`, pushes `/login`. The
  `CreateListingMsg` wiring routes `SessionExpired -> sessionExpired model` (L1254-55), passing the
  ORIGINAL model (discards `newSubModel`) — so a draft must be saved via a **Cmd emitted before** that
  routing, i.e. from within CreateListing's own branch.
- **Real localStorage glue** = `apps/core/assets/js/app.js` (esbuild entry; NOT the dev `index.html`):
  reads `stacks-auth` at boot → Elm flags (L164-179); `saveAuth`→`setItem` (L184-192);
  `clearAuth`→`removeItem` (L197-205). A draft port pair mirrors this exactly.
- **Boot flags**: `Main.init : Decode.Value -> …` / `decodeFlags` (L179/L218-246) reads auth from the
  flags value. A draft can be delivered the same way on a real reload; for the in-SPA return (no
  reload) a port round-trip is needed.
- **Return-after-login lands on home** (AntiLibrary, Main.elm L645-646), not the pre-expiry route. So
  restore is **not fully automatic** — it happens when the user navigates back to Sell-a-book. The
  login notice will tell them the draft is safe.

## Why Option 1 (persist) — Options 2 & 3 rejected
- **Option 3 (refresh-then-resubmit): REJECTED.** The residual scenario #182 actually covers is
  server-side **revocation** (proactive #173 renewal already prevents passive TTL expiry during active
  compose). A revoked token **cannot be refreshed**, so renew-and-retry fails in the exact target case.
- **Option 2 (acknowledged-loss note): insufficient alone.** Preserves nothing. We fold its *good*
  part (telling the user their work is safe) into Option 1 as the login-notice copy.
- **Option 1 (localStorage draft persistence): CHOSEN.** The only option that actually preserves the
  input in the revocation case. Machinery already exists to mirror.

## Approach (Option 1 + the acknowledgment as UX glue)
1. **Draft port pair** in `apps/core/assets/js/app.js` (mirror saveAuth/clearAuth) under a SEPARATE key
   `stacks-listing-draft` (so `clearAuth` on expiry does NOT wipe it): `saveListingDraft` →
   `setItem`; `clearListingDraft` → `removeItem`; and an init-time read delivered to Elm.
2. **Elm ports** (Main port module): `port saveListingDraft : Value -> Cmd msg`,
   `port clearListingDraft : () -> Cmd msg`, and hydrate via a request/response port pair
   (`port requestListingDraft : () -> Cmd msg` + `port gotListingDraft : (Value -> msg) -> Sub msg`)
   so a return WITHOUT a reload still restores. (Decoder tolerates absent/corrupt → no draft.)
3. **Draft encoder + decoder** for the 5 fields (new; the existing request encoder is wire-shaped, not
   form-shaped).
4. **Save on expiry**: CreateListing's `ListingCreated` 401 branch emits a new OutMsg
   `SessionExpiredWithDraft Value` (carrying the encoded draft); `Main.update` fires
   `saveListingDraft draft` THEN `sessionExpired model`. (The other two SessionExpired branches —
   `PlacementsReceived`, `ListingActivated` — have no user draft to save, so they keep plain
   `SessionExpired`.)
5. **Restore on return**: `CreateListing.init` requests the draft; `gotListingDraft` → a `DraftLoaded`
   Msg hydrates the form (re-selecting `selectedPlacementId` once placements load). Show a small
   "restored your draft" affordance + a **Discard** action (clears the draft).
6. **Clear on success**: on `ListingCreated (Ok …)`, fire `clearListingDraft ()` (the sale is created;
   the draft is stale).
7. **Login notice copy**: extend the existing `sessionExpiredNotice` path so that when a draft was just
   saved, the notice tells the user their listing is safe ("…your listing draft is saved — return to
   Sell a Book to finish."). Keep it in-voice, reuse the #173 notice styling.

## Phases
### Phase 1 — draft persistence + restore (elm-agent, + the app.js glue)
All of steps 1-7. Single cohesive phase (one page + its ports + the JS glue). Test-first per below.

## Test Plan / Validation
- **Elm unit (page-seam + pure):** (a) a 401 on `ListingCreated` yields `SessionExpiredWithDraft` with
  the encoded 5 fields (RED: constructor doesn't exist); (b) `DraftLoaded` hydrates every field + the
  selected placement; (c) encoder↔decoder round-trip (property-ish: encode→decode = identity for the 5
  fields); (d) `ListingCreated Ok` emits the clear-draft effect; (e) Discard clears. Non-vacuity: a
  non-401 submit error does NOT persist a draft / does NOT emit `SessionExpiredWithDraft`.
- **E2E (live, extend `auth.spec.ts` or a new `marketplace-draft.spec.ts`):** log in → go to
  `/marketplace/create` → fill the form → revoke/expire the token (same poison-token mechanism as the
  #178 tests) → trigger submit → assert redirect to `/login` WITH the draft-saved notice → sign back in
  → navigate to `/marketplace/create` → assert the 5 fields are **restored**. This is the load-bearing
  proof (the persistence survives the real redirect + a real re-login).

## Gate Plan
- 2A-iv reception (DoD table + testing-coordinator non-vacuity — the encoder round-trip must not be
  tautological). 2B-i `just verify`. 2B-ii spec coverage. 2B-iia **skip** (no DB/migration).
- **2B-iii Deploy-Preview + E2E: REQUIRED** (the persistence↔redirect↔re-login round-trip is only
  provable live). 2C: elm-reviewer + ux-reviewer (the restore affordance + notice copy are real UX).
  2F PE: light — confirm no draft leaks across users (key is per-browser localStorage; a different user
  logging in on the same browser must not inherit a draft → clear draft on a user mismatch at hydrate,
  or scope the key; PE to confirm the chosen guard).

## Open risk to close in review
**Cross-user draft leak**: `stacks-listing-draft` is browser-global. If user A composes, expires, and
user B logs in on the same browser, B must NOT see A's draft. Mitigation: stamp the draft with the
`userId` at save; on hydrate, only restore if it matches the current `auth.userId`; else clear. PE gate
verifies.

## Dependencies
#173 (interceptor + sessionExpired + notice), #178 (extended coverage — CreateListing already covered).
Agent: elm-agent. Same epic branch (`feat/124-e2e-auth`).
