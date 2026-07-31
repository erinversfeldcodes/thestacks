# Plan: Session Expiry — global 401 interceptor + token refresh
**Issue**: #173  ·  **US**: US-14.3.2
**Created**: 2026-07-10
**Status**: Approved

## Context
When a JWT expires (or is revoked server-side, #124 A2), the next authenticated API call returns
401. Today each page handles `Http.Error` locally, so an expired session leaves the user on a broken
authenticated view. Add (1) a global 401 interceptor that routes every authed-request 401 through one
path in Main (clear auth → `/login` + "session expired" notice), and (2) proactive silent renewal via
`POST /api/auth/refresh` so users rarely hit the expiry at all; on refresh failure, fall through to the
interceptor.

## Research Summary
- **Nested TEA with per-page `OutMsg`:** 13 page modules each define their own `OutMsg` (e.g.
  `Bookshelf.OutMsg = NoOut | NavigateTo Route`); `Main.update` handles each page's OutMsg in its own
  `case outMsg of` block. This is the idiomatic "one path in Main" channel.
- **57 bespoke authed `Http.request` calls** across ~13 pages; **no** shared HTTP helper. Api calls
  live in the pages (Upload 11, Blog/Post 10, …), only 3 in Main.elm.
- **Reusable logout pattern** at `Main.elm:1403`: `auth = Nothing` + `clearAuth ()` +
  `Nav.pushUrl Login` — the interceptor mirrors it.
- `Page.Login` already handles `Http.BadStatus 401` locally (`Login.elm:570`) and must keep doing so
  (login/register 401/403 are local, not global).
- Backend: `Stacks.Accounts.Guardian` has the `on_refresh` hook (delegates to `Guardian.DB.on_refresh`
  → rotates the `guardian_tokens` row); #174's trigger nulls the new token's `jwt`. #124 A2: a
  revoked (logged-out) token's row is deleted → verify fails → refresh cannot succeed.

## Approach Options
- **Option A (chosen):** `SessionExpired` OutMsg per authed page + a shared 401-detection helper +
  **one** `Main.sessionExpired` handler. Idiomatic for this app; central handling in one place.
  Touches ~13 authed pages (add the variant + wrap authed-result handling) — mechanical breadth.
- **Option B:** a shared `Api.expectAuthed` Expect wrapper emitting a per-page auth-error Msg — still
  per-page, and edits all 57 Api definitions. More invasive, not cleaner. Rejected.
- **Option C:** refactor all pages to a single shared OutMsg/Effect type first — large cross-cutting
  refactor beyond this issue. Rejected.

**Human decisions (2026-07-10):** include refresh now (not deferred); roll the interceptor out to all
authed pages in one phase.

## Phases

### Phase 1: `POST /api/auth/refresh` endpoint (backend)
**Objective**: A valid, non-revoked, non-expired token can be exchanged for a fresh JWT; revoked/expired
cannot.
**Agent(s)**: elixir-agent
**Steps**:
1. Add `POST /api/auth/refresh` (router + `AuthController.refresh`): read the `Authorization: Bearer`
   token; verify it (Guardian + guardian_db presence check); on success re-issue via `Guardian.refresh`
   (or decode→`encode_and_sign`) → return `{token, user}` like login; the `on_refresh`/re-sign path
   rotates the `guardian_tokens` row (new jwt nulled by #174's trigger).
2. **Revoked token → 401** (its `guardian_tokens` row is gone, #124 A2). **Expired token → 401.**
   Malformed/absent → 401.
3. Keep the new token's TTL consistent with login (8h access).
**Test Command**: `cd apps/core && mix test test/stacks_web/auth_controller_test.exs`
**DoD (phase)**:
- [ ] `POST /api/auth/refresh` returns a fresh JWT for a valid token (happy)
- [ ] Revoked (logged-out) token → 401; expired token → 401 (sad, coordinates with #124 A2)
**Reviewers**: elixir-reviewer + contract-reviewer (refresh response shape)

### Phase 2: Global 401 interceptor + silent renewal (frontend)
**Objective**: Every authed-request 401 routes through one Main handler (clear auth → `/login` +
expiry notice); proactive renewal before expiry; refresh failure falls through to the interceptor.
**Agent(s)**: elm-agent
**Steps**:
1. Add a `SessionExpired` variant to each authenticated page's `OutMsg`; a shared helper detects
   `Http.BadStatus 401` from an authed request and emits it (uniform, not bespoke per page).
2. `Main.sessionExpired` handler (single): `auth = Nothing`, `clearAuth ()`, `Nav.pushUrl /login`, set
   a "session expired" notice (distinct from invalid-credentials). Every page's `case outMsg of`
   routes `SessionExpired` to it.
3. **Exclude** login/register — `Page.Login` keeps its local 401/403 handling.
4. **Silent renewal:** before the access token nears expiry (derive from claims/8h TTL), call
   `Api.refresh` and `saveAuth` the new token; on refresh failure → the interceptor.
5. Login page renders the expiry notice.
**Test Command**: `cd frontend && npx elm-test`  ·  E2E: `e2e/tests/auth.spec.ts`
**DoD (phase)**:
- [ ] Global `Http.BadStatus 401` interceptor in Main: clears auth, `clearAuth`, redirects `/login`, expiry notice
- [ ] Login/register endpoint 401/403 excluded from the global redirect
- [ ] Elm unit + `elm-program-test` for the interceptor (happy + sad: login/register 401 does NOT redirect)
- [ ] Silent renewal: refresh success renews; refresh failure → interceptor
- [ ] E2E: expired/revoked token → redirect to `/login`
**Reviewers**: elm-reviewer + ux-reviewer + contract-reviewer

### Parallel Execution
Phase 2 depends on Phase 1's endpoint — sequential.

## Gate Plan
- 2B-i Regression: `just verify` (elixir) + `scripts/test-elm.sh`. Required each phase.
- 2B-ii Spec Coverage: orchestrator-built. Required.
- 2B-iia Fresh DB: **skip** — no migration/schema change (uses existing guardian_tokens).
- 2B-iii Deploy-Preview + E2E: **run** (final phase) — user-facing; the expired/revoked→`/login` E2E
  is a DoD item.
- 2F Principal Engineer: required (final phase; auth/session-lifecycle, security lens).

## Open Questions
- Silent-renewal trigger mechanism (Time subscription vs a scheduled Cmd on token receipt) — elm-agent
  to choose the simplest robust option in Phase 2; must not busy-loop.

## Integration Handoffs
- Phase 1 → Phase 2: the `/api/auth/refresh` response shape (token + user), consumed by `Api.refresh`.
- Coordinates with #174 (trigger nulls the refreshed token's jwt) and #124 A2 (revocation gates refresh).
- This is the last child before the epic PR from `feat/124-e2e-auth`.
