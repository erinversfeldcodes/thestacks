# Plan: Token-rotation multi-tab / in-flight race → no spurious logout
**Issue**: #180  ·  **Created**: 2026-07-11  ·  **Status**: Awaiting approval

## Context
#173's 7h silent renewal rotates the access token; #179 then made a non-current token BURN the whole
family (reuse-detection). So the two rotation races now cause a *family burn* → spurious logout of ALL
tabs, not just a single 401:
- **In-flight**: a request that left with `T0` arrives after the rotation → `verify_claims` sees
  `T0.jti != current_jti(T1)` → burns the family. The frontend cannot fix this (the request already
  left) → needs a backend grace.
- **Multi-tab**: tab A renews (`T0→T1`, saves `T1`); tab B still holds `T0` in memory → its next
  request burns the family. Needs cross-tab propagation so tab B adopts `T1`.

Neither is a security hole (the token was validly rotated); both are jarring UX. #180 was sequenced
after #179 so the grace layers onto the family gate.

## Research Summary (grounded — file:line)
**Backend (#179, this session):** `check_token_family/3` (`accounts.ex`) + `verify_claims/2`
(`guardian.ex`): a `jti != current_jti` → reuse → `revoke_family_and_burn`. `op.auth_token_families`
has `current_jti`; refresh advances it (`rotate_token_family`). Config pattern `{n, unit}` (e.g.
`:session_absolute_cap`).
**Frontend (#173):** `Auth = {user, token}` (`Main.elm:158`); `renewAuthToken : AuthResponse -> Auth
-> Auth` (pure, exposed, `Main.elm:613`) swaps only the token. `TokenRefreshed (Ok ..)` adopts +
`saveAuth` (`Main.elm:1729`); `(Err _)` → `sessionExpired` (`:1745`). `sessionExpired` (`:593`) clears
auth + `clearAuth ()` + `/login`. `decodeFlags`/`authDecoder` (`:241`) decode the stored `stacks-auth`
JSON (`{token,userId,email,displayName,role}`); `encodeAuth` (`:574`) is the mirror. Ports `saveAuth`
/`clearAuth` (Main.elm:74/77) → `app.js:184/197` (`setItem`/`removeItem` on `stacks-auth`). **No
`storage`/`BroadcastChannel` listener exists.** Inbound-port pattern: `gotListingDraft`/`uploadStreamEvent`
declared in Main.elm + `.send` in `app.js` + registered in `subscriptions` (`Main.elm:1814`).
**Testability:** `Main` (real `Nav.Key`) isn't program-testable; the pure adopt/decide helper IS
(pattern: `SessionExpiryTest.elm` `renewProgram`/`renewAuthTokenSwapsTokenKeepsUser`). Playwright
supports two `ctx.newPage()` in ONE context — required because the `storage` event fires only across
same-context tabs (`private-session.spec.ts:11-13`).

## Design (backend grace + frontend cross-tab — BOTH needed given #179)
### Phase 1 — backend rotation grace window (database-agent + security-agent)
1. **Migration**: add `previous_jti text NULL` + `rotated_at utc_datetime_usec NULL` to
   `op.auth_token_families` (coexists with everything; no index needed — read by PK). Forward-only.
2. **rotate_token_family** (refresh): set `previous_jti = <old current_jti>`, `rotated_at = now`,
   `current_jti = <new jti>` (one upsert).
3. **check_token_family/3** — insert a grace branch BEFORE the reuse-burn:
   - `jti == current_jti` → `:ok`
   - `jti == previous_jti` AND `now - rotated_at <= grace` → **`:ok`** (benign in-flight / propagation;
     do NOT burn, do NOT advance)
   - else (older jti, or previous past grace, or unknown) → **reuse → burn** (unchanged #179 posture)
4. **Config** `config :core, :session_rotation_grace, {20, :second}` (**duration TBD — see decision**).
   Short by design: it's the ONLY window a stolen just-rotated token is honoured.
**DoD**: previous jti within grace → accepted (no burn); previous jti past grace → family burned;
older/unknown jti → burned; current → ok. Unit + a live HTTP check (in-flight replay within grace 200,
after grace 401+burn). `just verify`.

### Phase 2 — frontend cross-tab propagation (elm-agent)
1. **Inbound port** `authChanged : (Decode.Value -> msg) -> Sub msg`; register in `subscriptions`.
2. **app.js**: `window.addEventListener("storage", e => { if (e.key === "stacks-auth")
   app.ports.authChanged.send(e.newValue) })` — fires in OTHER same-context tabs only (writer never
   sees its own event, no loop). `newValue` is the new JSON (adopt) or `null` (a sibling `clearAuth`
   → logout).
3. **Main**: `AuthChangedExternally Value` Msg → a PURE helper `adoptExternalAuth : Value -> Maybe Auth
   -> ExternalAuthOutcome` (Adopt newAuth | LogOut | Ignore): decode; if a token present and differs
   from the current in-memory token → Adopt (swap token, keep user via the `renewAuthToken` idiom);
   if `null`/cleared → LogOut (→ `sessionExpired`); if same/undecodable → Ignore. This keeps tabs
   converged on the current token so tab B never presents a stale `T0`.
4. Pure helper is unit-tested (adopt-newer / logout-on-clear / ignore-same); the `storage`-event
   delivery + redirect are E2E.
**DoD**: a renewal in tab A updates tab B's in-memory token (tab B not logged out); a logout in tab A
logs out tab B. Unit test for `adoptExternalAuth`; a two-page-one-context Playwright test.

## Why not frontend-only (Option 1 alone)
"Re-read localStorage before `sessionExpired`" can't help the in-flight case: with #179 the family is
already BURNED by the time the 401 returns, so adopting `T1` then hitting a revoked family just 401s
again. The backend grace is what prevents the burn. (A re-check safety-net is optional — see decision.)

## Gate Plan
- Phase 1: 2A test-first (db + security); 2B-i `just verify`; 2B-iia fresh-DB (migration); 2B-iii
  deploy + live HTTP grace check (SKIP_VISION=1); 2C security-reviewer + database-reviewer; 2F PE
  (does the grace weaken #179? — bounded to a few seconds).
- Phase 2: 2A elm test-first; 2B-i elm-test + `just verify`; **2B-iii two-tab Playwright** (SKIP_VISION=1);
  2C elm-reviewer.

## Open decisions (AskUserQuestion)
1. Grace-window duration (recommend 20s — covers in-flight + storage propagation; minimises the
   honoured-stolen-token window).
2. Include the belt-and-suspenders frontend re-check-before-logout (Option 1) in addition to grace +
   cross-tab, or keep scope to the two that fully cover the races?

## Dependencies
#173 (renewal/interceptor), #179 (family gate — the grace extends `check_token_family`). Agents:
database-agent + security-agent (P1), elm-agent (P2). Same epic branch.
