# Issue #173 — Complete

**Issue**: #173 — Session Expiry: global 401 interceptor + token refresh (US-14.3.2)
**Branch**: `173-session-expiry-401-interceptor` (off `feat/124-e2e-auth`)
**Commit**: `401855e` — merged into `feat/124-e2e-auth`
**Completed**: 2026-07-10
**Agents**: elixir-agent (Phase 1), elm-agent (Phase 2) · **Revision cycles**: 1 (Phase 2 ux polish)

## What shipped
**Phase 1 — `POST /api/auth/refresh` (backend).** Behind the `:authenticated` pipeline; rotates the
token (revoke old + `encode_and_sign` a fresh 8h) and returns `%{token, user}` (byte-identical to
login). Revoked/expired/absent → 401 (pipeline). Coordinates with #124 A2 (revocation) and #174
(the refreshed token's `jwt` is nulled by the trigger).

**Phase 2 — global 401 interceptor + proactive silent renewal (frontend).**
- `Api.isUnauthorized` detects `Http.BadStatus 401`; each authed page's `OutMsg` gains a
  `SessionExpired` variant; every one routes to a single `Main.sessionExpired` (auth=Nothing,
  `clearAuth ()`, `Nav.pushUrl /login`, distinct expiry notice) — the DoD's "one path in Main."
- Proactive renewal: a 7h `Process.sleep` → `Api.refresh` → adopt the new token + `saveAuth` +
  reschedule; refresh failure → the interceptor.
- Login/register 401/403 stay local (`Page.Login`). Notice is styled (amber "lamplight" panel,
  distinct from the maroon error), `role="status"`, in-voice copy ("The library closed your session
  for safekeeping — sign in again to return.").

## Coverage scope (important)
The interceptor covers the **8 authed pages that have an `OutMsg` channel** (Bookshelf, BookDetail,
ReadingPile, LookingForHome, Groups, Groups/Detail, CreateListing, Upload). **11 authed pages without
an OutMsg channel** (Admin×3, Blog×2, Marketplace/MyListings, Catalogue, Search, Settings×3) need the
3-tuple conversion first → tracked in **#178**. The PE confirmed this is **UX-only, not an auth
bypass**: the backend `:authenticated` pipeline rejects every expired/revoked token 401 regardless.

## Gate record
- Phase 1: elixir-reviewer + contract-reviewer APPROVED; `auth_controller_test` 38/0; format/credo/sobelow clean.
- Phase 2: 2A-ii page-seam RED (a 401 must stop resolving to `NoOut`) → GREEN; 2B-i elm gate
  (test-elm 561/0, lint-elm clean); 2C elm-reviewer + contract-reviewer APPROVED, ux SHIP+polish.
- Both: `just verify` exit 0. 2B-iia skip (no migration).
- **2B-iii Deploy-Preview + E2E: PASS** — deploy succeeded on real Fly; **`auth.spec.ts` "Session
  expiry" redirects to `/login` with the notice (8.8s), full E2E 195/0** — the end-to-end proof
  `Main.sessionExpired` couldn't be unit-tested for (Nav.Key/`NoUnused.Exports` constraint).
- 2F Principal Engineer: GREEN (no P0/P1).

## Notable engineering constraint
`Main.elm` is a `Browser.application` (real `Nav.Key` + opaque `Cmd`), so `Main.sessionExpired` is
NOT elm-program-testable, and `NoUnused.Exports` forbids exposing an untested symbol. Handled by:
page-seam unit tests (`OutMsg /= NoOut`), a pure `renewAuthToken` unit test, the `Login.expiredInit`
view seam for the notice, and the live E2E as the redirect proof.

## Follow-ups filed (all non-blocking, out of scope)
- **#178** — extend the interceptor to the 11 OutMsg-less pages (+ the PE's free boot-time
  `GotPlacementCheck` 401 hook).
- **#179** (P2) — absolute session-lifetime cap + refresh-token reuse detection (silent renewal made
  the session sliding).
- **#180** (P3) — token-rotation multi-tab / in-flight race → spurious logout.
- **#181** (P3) — metric on refresh revoke-failure.
- **#182** (P3) — preserve CreateListing form on expiry.

## Epic
Last child of `feat/124-e2e-auth` (#124 + #175 + #177 + #176 + #174 + #173). Epic complete; ready for
the PR. The session-lifecycle chain is internally consistent — the `:authenticated` pipeline is the
gate; #124 A2 revocation and #174 jwt-null both verified to interact correctly with the new refresh.
