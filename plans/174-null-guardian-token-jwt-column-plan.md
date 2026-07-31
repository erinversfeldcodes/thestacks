# Plan: Stop persisting raw JWTs in op.guardian_tokens
**Issue**: #174
**Created**: 2026-07-10
**Status**: Approved

## Context
`op.guardian_tokens` (added with guardian_db in Issue #124 A2) stores the full signed bearer token
in the `jwt` column, but that column is **never read** — Guardian.DB verifies by `jti`+`aud` and
purges by `exp`. A SELECT-capable compromise of the table therefore yields directly replayable
sessions. Stop persisting a usable token so a dump contains only non-secret bookkeeping columns.

## Research Summary
- `op.guardian_tokens` is **not** proto-managed (hand-migrated, `20260708120000_create_guardian_tokens.exs`);
  `jwt` is `:text` and already nullable (not in guardian_db's `@required_fields = [jti, aud]`).
- guardian_db 3.0.0 flow: `after_encode_and_sign → store_token → Token.create(claims, jwt)` where
  `changeset` does `Map.put("jwt", jwt)`. `find_by_claims` (on_verify) matches `jti`+`aud` — never
  `jwt`. `purge_expired_tokens` uses `exp`. So `jwt` is write-only, confirming the issue.
- **Refresh is dormant:** `Stacks.Accounts.Guardian.on_refresh/3` exists but no endpoint calls it
  (token refresh is #173's stretch). So only login (`after_encode_and_sign`) persists tokens today —
  but `on_refresh` delegates to guardian_db's internal `after_encode_and_sign` with the real token,
  so an app-side override alone would leave a latent gap when #173 lands.
- Test surface: `apps/core/test/stacks/accounts/guardian_test.exs`,
  `apps/core/test/stacks/workers/guardian_token_sweep_job_test.exs`.

## Approach Options
- **Option A (chosen):** a `BEFORE INSERT OR UPDATE` DB trigger on `op.guardian_tokens` that forces
  `NEW.jwt = NULL`. Enforced at the data layer, so **no** code path (login, the future refresh,
  anything) can ever persist a raw token — the strongest form of "a dump contains no usable token".
  Migration-only, no app change.
- **Option B:** pass `nil` as the token in `after_encode_and_sign`. One-line, covers login now, but
  `on_refresh` (guardian_db internal) still stores the real token → weaker, path-dependent. Rejected.
- **Option C:** drop the `jwt` column + custom Token schema. guardian_db 3.0 hardcodes casting `jwt`
  in its changeset; no clean config hook to override its Token module. Too invasive. Rejected.
- **Option D:** store a SHA-256 hash. The column is never read, so a hash adds no value over NULL and
  still stores a correlatable artifact. NULL is strictly better. Rejected.

**Human decisions (2026-07-10):** Option A (DB trigger); full 2B-iii deploy gate; embed a test audit
with an appropriate live-stack (`:deployed_only`) E2E test validating `jwt IS NULL` on a real preview.

## Phases

### Phase 1: Force op.guardian_tokens.jwt to NULL via a DB trigger
**Objective**: No raw bearer token is ever persisted; all four Guardian.DB hooks still function.
**Agent(s)**: database-agent (migration/trigger) + security verification
**Steps**:
1. Migration:
   - `CREATE FUNCTION` (e.g. `op.guardian_tokens_null_jwt()`) returning trigger that sets
     `NEW.jwt := NULL; RETURN NEW;`
   - `CREATE TRIGGER ... BEFORE INSERT OR UPDATE ON op.guardian_tokens FOR EACH ROW EXECUTE FUNCTION …`
   - One-time scrub: `UPDATE op.guardian_tokens SET jwt = NULL WHERE jwt IS NOT NULL;`
   - `down`: drop trigger + function (leave the column — it's guardian_db's schema).
   - Non-destructive (no column drop) → squawk-safe; `@disable_ddl_transaction` not needed.
2. Verify the four Guardian.DB hooks end-to-end (login stores row with `jwt IS NULL`; verify passes;
   logout/`revoke` deletes the row → next request 401; sweep purges expired). No app-code change
   expected; if any is needed, keep it minimal.
3. Tests (see audit).
4. Regenerate the embedded test audit to GREEN.
**Test Command**: `cd apps/core && mix test test/stacks/accounts/guardian_test.exs test/stacks/workers/guardian_token_sweep_job_test.exs`
**DoD Items**:
- [ ] `op.guardian_tokens.jwt` no longer stores a usable bearer token (NULL, enforced by trigger)
- [ ] Migration scrubs existing rows to NULL
- [ ] Login / verify / logout-revocation / expired-sweep all still pass (no #124 A2 regression)
- [ ] Test asserts the persisted row has no replayable token (`jwt IS NULL`) — trigger fires on INSERT and UPDATE
- [ ] Live-stack `:deployed_only` test: login against a real preview → `op.guardian_tokens.jwt IS NULL`
- [ ] `just verify` passes
- [ ] Test audit (embedded) is GREEN

## Test Audit (baseline — to embed in the issue via the `test-audit` skill)
Compact (security/DB hardening, no US surface). Applicable layers:
- **L3 DB/migration (SECURITY):** ❌ trigger nulls jwt on INSERT+UPDATE; existing rows scrubbed; a
  dump of guardian_tokens has no replayable token. → local integration + fresh-DB gate.
- **L2 Auth guards (SECURITY):** ❌ the four Guardian.DB hooks still function with jwt NULL
  (login/verify/revoke/sweep). → guardian_test + sweep_job_test.
- **Live-stack:** ❌ login on a real Fly/Neon preview → `op.guardian_tokens.jwt IS NULL`
  (`:deployed_only`, direct Postgrex). Playwright is the wrong tool (DB-level invariant) → deployed test.
- L1,4–13: n/a — no API-shape/US/frontend change.

## Gate Plan
- 2B-i Regression: `mix test` (elixir) + `just verify`. Required.
- 2B-ii Spec Coverage: orchestrator-built. Required.
- 2B-iia Fresh DB: **RUNS** — migration present (drop/create/migrate/seed/test + dbt).
- 2B-iii Deploy-Preview + E2E: **RUN (human elected)** — applies the migration on Neon; the
  `:deployed_only` test confirms `jwt IS NULL` live.
- 2F Principal Engineer: required (security lens on the token store).

## Open Questions
None.

## Integration Handoffs
None — single phase. Lands on `feat/124-e2e-auth` via merge. Coordinates with #173 (refresh): the
trigger already covers the future refresh path, so #173 needs no extra work here.
