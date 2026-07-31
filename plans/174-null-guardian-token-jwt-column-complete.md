# Issue #174 — Complete

**Issue**: #174 — Stop persisting raw JWTs in op.guardian_tokens
**Branch**: `174-null-guardian-token-jwt-column` (off `feat/124-e2e-auth`)
**Commit**: `a4e8363` — merged into `feat/124-e2e-auth`
**Completed**: 2026-07-10
**Agent**: database-agent · **Revision cycles**: 0 (clean first pass)

## What shipped
A `BEFORE INSERT OR UPDATE` DB trigger on `op.guardian_tokens` forces `NEW.jwt = NULL`, plus a
one-time `UPDATE … SET jwt = NULL WHERE jwt IS NOT NULL` scrub of existing rows
(`apps/core/priv/repo/migrations/20260710000000_null_guardian_token_jwt.exs`). The `jwt` column is
write-only (guardian_db verifies by jti+aud, purges by exp), so nulling it removes a replayable-token
surface without touching the auth flow. Enforced at the data layer → covers login, the future refresh
(#173), and any path. No app-code change (`guardian.ex` untouched); column kept (guardian_db's schema),
just always NULL.

## Approach
Chose the DB trigger over an app-side `after_encode_and_sign` override: the trigger is path-independent
(the PE confirmed `on_refresh` funnels through guardian_db's internal insert → the trigger), whereas
the app-side option would leave a latent gap when #173 wires refresh. Dropping the column was rejected
(guardian_db 3.0 hardcodes casting `jwt` in its changeset → would need a fork). Hashing adds no value
over NULL for a never-read column.

## Gate record (all first-pass green)
- 2A-iv DoD + testing-coordinator: PASS — direct-SQL mutant proved the trigger is load-bearing
  (drop trigger → raw token persists); scrub-of-existing-rows a non-blocking note.
- 2B-i `just verify` exit 0 · 2B-ii spec coverage PASS.
- 2B-iia Fresh-DB: PASS — drop/create/migrate-from-scratch (incl. trigger) + seed + 2269 tests + dbt.
- 2B-iii Deploy-Preview + E2E: PASS — migration applied on the preview Neon branch; a `:deployed_only`
  test confirmed `guardian_tokens.jwt IS NULL` after a live login on real Neon; full E2E 195/0.
- 2C database-reviewer: APPROVED · 2F Principal Engineer: GREEN (no P0/P1/P2).

## Tests
- `apps/core/test/stacks/accounts/guardian_db_jwt_test.exs` — jwt NULL on INSERT + UPDATE (bookkeeping
  columns intact); verify + revoke regression guards. Mutation-verified.
- `apps/core/test/stacks_web/guardian_jwt_deployed_test.exs` (`:deployed_only`) — logs in through real
  Fly, reads the preview `op.guardian_tokens` via direct Postgrex, asserts `jwt IS NULL`.

## Deferred / not filed (P3, out of scope — per PE/TC)
- An optional scrub-specific test (drop trigger → insert raw → recreate → run scrub → assert NULL) —
  low value; the trigger is the forward invariant and the live test covers the real asset.
- The decoded `claims` column (guardian_db also persists the claims map) — NOT a replay vector (no
  signature); could optionally be nulled by the same trigger for strict minimalism.

## Coordination
Confirmed at code level that the trigger already covers #173's future refresh path — #173 needs no
extra work on token persistence.
