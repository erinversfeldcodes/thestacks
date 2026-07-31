# Issue #180 — Complete

**Issue**: #180 — Token-rotation multi-tab / in-flight race → no spurious logout
**Branch**: `180-token-rotation-multitab-race` (off `feat/124-e2e-auth`)
**Completed**: 2026-07-12
**Agents**: security-agent + database-agent (P1), elm-agent (P2) · **Revision cycles**: 1 (frontend P1a/P1b)

## What shipped
#173's silent renewal + #179's reuse-burn meant a benign rotation race (in-flight request with the
just-rotated token, or a peer tab still holding it) burned the whole family → spurious logout of ALL
tabs. Fixed with a backend grace + frontend cross-tab, both needed:

**Backend grace window (20s, configurable).** `op.auth_token_families` gains `previous_jti` +
`rotated_at`; refresh records the predecessor. `check_token_family/3` gains a grace branch: the
IMMEDIATE predecessor within 20s → `:ok` (no burn); anything else (older jti, unknown, previous
past-grace) still burns. Scoped to `previous_jti` only, server-set `rotated_at`, doesn't mint/advance
`current_jti`, fail-safe unit catch-all. Net effect: an in-flight just-rotated token no longer burns
the family (the current token / other tabs survive); the token's own request still 401s (its row was
revoked on rotation) but the frontend adopts the new token.

**Frontend cross-tab + re-check net.** New `authChanged` inbound port (a `storage` event on
`stacks-auth` → adopt a newer sibling-tab token via `renewAuthToken`, or log out on a sibling
`clearAuth`). Plus a re-check-before-logout net: all ~25 `SessionExpired` sites route through one
`handleSessionExpiry` that fires `requestStoredAuth` and adopts a newer stored token before logging
out. All decisions are pure helpers (`adoptExternalAuth`, `resolveRecheck`, `parkPending`), unit-tested.

## Gate record
- 2A test-first each phase. 2C: **security-reviewer APPROVE-WITH-NITS** — grace is correctly bounded
  (previous-jti-only, 20s, server-set timestamp, no mint, cannot be chain-extended because guardian_db
  deletes the rotated row); **elm-reviewer REQUEST-CHANGES → resolved**: found two real P1s (a cross-tab
  adopt left `pendingLogout` parked → the exact spurious logout #180 fights; a reschedule-storm on
  page-origin adopts) — both fixed (`pendingLogout = Nothing` on adopt; a `fromRenewal` flag gating the
  reschedule). Plus the security grace-unit catch-all.
- 2B-i `just verify`: **exit 0**. 2B-iia fresh-DB: clean (local). Backend 122 tests; frontend 631.
- **2B-iii live: PASS** — backend grace check on Fly preview (within-grace previous token 401s but does
  NOT burn → current token survives 200; past-grace → 401 + family burned) and `rotation-race.spec.ts`
  2/2 live (sibling rotation doesn't log out the other tab; sibling logout propagates). SKIP_VISION=1 →
  no Modal spend. (Preview DB had to be patched — see Incident.)
- 2F PE: folded into the security review (grace bounded; #179 preserved outside the window; the
  multi-tab false-positive #179 accepted is now the case this closes).

## Incident (must-read for the merge/deploy)
The untracked Phase-1 migration file `20260711120000_add_rotation_grace_to_auth_token_families.exs`
**vanished from disk mid-issue** (other #180 untracked files survived; cause unconfirmed — a
`git checkout feat/124→180` appears in the reflog). It was RECREATED from the Phase-1 report and the
schema/code, and fresh-DB rebuilt locally. **Separately**, the Fly preview deploy reported "Migrations
already up" yet the preview Neon DB (CoW from staging) had NEITHER the migration record NOR the
columns → every authed request fail-closed 401 (the exact outage the #179 runbook describes). I
confirmed the diagnosis by ALTERing the ephemeral preview branch to add the two columns (auth
recovered 401→200) so the live gate could run. **Follow-up recommended**: investigate why
`Stacks.Release.migrate()` reported "already up" for a pending migration — a deployment-integrity risk
that could silently skip other migrations.

## Files
config.exs · accounts.ex (grace branch, within_rotation_grace?, catch-all) ·
accounts/auth_token_family.ex (previous_jti/rotated_at) · auth_controller.ex (rotate records
predecessor) · priv/repo/migrations/20260711120000_add_rotation_grace_to_auth_token_families.exs
(recreated) · frontend/src/Main.elm (ports, adoptExternalAuth, handleSessionExpiry/forceSessionExpiry,
pendingLogout, resolveRecheck, parkPending) · apps/core/assets/js/app.js (storage listener +
requestStoredAuth) · tests: accounts_test, auth_controller_test, frontend/tests/RotationRaceTest.elm,
e2e/tests/rotation-race.spec.ts.

## Batch
Follow-up #5 (LAST) of #178–182 — the batch (order 181 → 178 → 182 → 179 → 180) is COMPLETE.
