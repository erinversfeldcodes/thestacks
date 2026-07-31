# Plan: Absolute session-lifetime cap + refresh-token reuse-detection
**Issue**: #179  ·  **Created**: 2026-07-11  ·  **Status**: Awaiting approval

## Context
#173's proactive renewal made the 8h access token a **sliding session** — no absolute cap, no
rotation-family/reuse-detection. Two gaps: (1) a session renews forever (no "re-auth after N days");
(2) a stolen-then-rotated token survives the victim's own logout (logout revokes only the current
`jti`, not the attacker's rotated chain). Add an absolute cap + family tracking so a session is
bounded and a logout/compromise kills the whole chain.

## Research Summary (grounded — file:line)
- **Guardian module** `apps/core/lib/stacks/accounts/guardian.ex`: `build_claims/3` (L31-43) is the
  custom-claim hook (today only admin claims; the else branch L40-41 is where access-token claims go).
  `verify_claims/4` (L45-56) is the global rejection hook. guardian_db wired via module hooks
  (`after_encode_and_sign`/`on_verify`/`on_revoke`, L68-95).
- **guardian_db 3.0** persists the FULL claims map to the `claims` jsonb column
  (`deps/guardian_db/.../token.ex` changeset) — custom claims are readable back. `destroy_by_sub/1`
  (`ecto_adapter.ex:52-61`) = `where sub == ^sub |> delete_all` (indexed) → revoke-all-for-user is a
  one-liner. No built-in query-by-family. on_revoke DELETES the row.
- **AuthController** `auth_controller.ex`: `login/2` L49 and `refresh/2` L182 both
  `Guardian.encode_and_sign(user)` with NO claims/opts → default 8h TTL, no session anchor, no family.
  `logout/2` L96 revokes current token only. Password change =
  `UserSettingsController.update_password/2` (`user_settings_controller.ex:73-92`) — does NOT touch
  tokens today.
- **`op.guardian_tokens`** (hand-migrated, NOT proto): create migration `20260708120000` has
  `jti(PK), aud, typ, iss, sub, exp, jwt, claims(jsonb), inserted_at/updated_at`, indexes on `sub` +
  `exp`. #174 trigger `20260710000000` nulls `jwt` BEFORE INSERT OR UPDATE — new columns coexist fine
  (it only touches `jwt`).
- **Verification/401**: pipeline `AuthPipeline` → `on_verify` (jti+aud lookup; missing row ⇒ fail) →
  `AuthErrorHandler` 401. Rotation deletes the old row, so a replayed old token 401s AT THE PIPELINE
  (never reaches `refresh/2`).
- **Tests**: `auth_controller_test.exs` refresh/logout/revoke describe blocks (L374-535) assert
  revocation behaviourally (old token → 401 on `/me`); expiry via `ttl: {-1,:hour}`. Deployed template:
  `guardian_jwt_deployed_test.exs` (`:deployed_only`, direct Postgrex to preview, Req login w/ retry).

## Phases (split per the issue's guidance — cap is clean/small; reuse-detection is the hard part)

### Phase 1 — Absolute lifetime cap (security-agent) — NO migration
1. `build_claims/3` (access-token branch): stamp `"sst"` (session-started-at) = `claims["iat"]` at
   login (the anchor). It persists into the `claims` jsonb automatically.
2. `refresh/2`: read `sst` from `Guardian.Plug.current_claims(conn)`; if `now - sst > @cap` → revoke +
   401 (the #173 interceptor sends the user to `/login`). Else mint carrying it forward:
   `encode_and_sign(user, %{"sst" => sst})` so the cap SURVIVES rotation (doesn't reset).
3. Cap = configurable (`config :core, :session_absolute_cap, {7, :day}` — **duration TBD, see decision**).
4. Tests: unit — refresh just under cap → 200 + `sst` preserved in the new token; refresh past cap →
   401 (mint a token with an old `sst` via `encode_and_sign(user, %{"sst" => old_ts})`). Plus a
   `:deployed_only` check that an over-cap token is refused on a live preview.
**DoD**: refresh past the cap → 401; cap survives rotation; unit + deployed tests; `just verify`.

### Phase 2 — Family tracking + reuse-detection + revoke-family (database-agent + security-agent)
**DECIDED: Design B — a dedicated `op.auth_token_families` table, with reuse gated in `verify_claims`.**

**Critical mechanism note.** guardian_db deletes the old row on rotation, so a replayed rotated token
401s at the *pipeline* (missing row) before `refresh/2` sees it — you CANNOT detect reuse at refresh.
The correct gate is **`verify_claims/4`** (runs on every authed request): accept an access token only
if its `jti` equals its family's `current_jti`; ANY other jti in the family (an already-rotated OR
replayed token) is rejected AND triggers family revocation. This makes old-token invalidation and
reuse-detection both flow from `family.current_jti` rather than from guardian_db's delete-on-rotate.

1. **Migration (database-agent):** `op.auth_token_families` — `family_id uuid PK, user_id uuid NOT
   NULL, current_jti text NOT NULL, session_started_at timestamptz NOT NULL, revoked_at timestamptz
   NULL, created_at/updated_at`. Index on `user_id` (revoke-all) and `current_jti`. Hand-migrated (like
   guardian_tokens; not proto). Grants: `stacks_app` CRUD, NOT `stacks_dbt`. Coexists with #174 trigger
   (different table). Add a minimal Ecto schema for app-side queries.
2. **`build_claims/3`:** add a `family_id` claim to access tokens (generated at login; carried forward
   unchanged on every refresh).
3. **login/2:** generate `family_id`; `encode_and_sign(user, %{"family_id" => fid, "sst" => now})`;
   from the returned claims read the new `jti`; INSERT the family row (family_id, user_id,
   current_jti = jti, session_started_at = now).
4. **refresh/2 (legit rotation):** verify_claims has already confirmed jti == current_jti to get here.
   Mint the new token carrying `family_id` + `sst` forward; read the new jti; UPDATE
   `family.current_jti = new_jti`; revoke the old token (existing guardian_db path). (Cap check from
   Phase 1 still applies.)
5. **verify_claims/4 (the reuse gate):** for access tokens with a `family_id`: load the family; if
   missing/`revoked_at` set → reject; if `jti != family.current_jti` → **REUSE/rotated** → revoke the
   whole family (mark `revoked_at` + `destroy_by_sub` the user's guardian_tokens, or a by-family delete)
   → reject. Idempotent; a rejected verify must not 500. Watch perf: one indexed family lookup per
   authed request (guardian_db's on_verify already does a jti lookup, so this is +1 indexed query).
6. **revoke-family wiring:** `logout/2` → revoke the current token's FAMILY (kills an attacker's rotated
   chain sharing the victim's family), not just the jti. `update_password/2`
   (`user_settings_controller.ex:73`) → revoke ALL the user's tokens + families
   (`destroy_by_sub` + delete families by user_id) = "password change logs out everywhere".
7. **Sweep-job interaction:** ensure `guardian_token_sweep_job` (expired-token prune) also prunes
   expired/revoked family rows so the table doesn't grow unbounded; must not delete a live family.

**DoD**: a replayed already-rotated token → whole family revoked (verified on any authed request);
logout revokes the family; password change revokes all the user's tokens/families; unit +
`:deployed_only` tests; fresh-DB migration check; `just verify`.

**Note (Phase 1 ↔ 2 overlap):** the cap can also live on the family row (`session_started_at`), but
Phase 1 ships the cap claim-based + independently; Phase 2 is additive. Reconcile only if clean.

## Gate Plan
- Per phase: 2A test-first (security-agent leads; database-agent for the migration in P2) + reception.
- 2B-i `just verify`. 2B-ii spec coverage. **2B-iia fresh-DB REQUIRED in P2** (new migration —
  fresh-DB migrate check). **2B-iii Deploy-Preview + `:deployed_only`** REQUIRED both phases (the DoD
  demands a live check that a capped/reused token is rejected). 2C: security-reviewer +
  (P2) database-reviewer. 2F PE (security-critical — reuse-detection correctness + no-lockout).

## Decisions (locked 2026-07-11)
1. **Absolute cap = 7 days** (configurable `config :core, :session_absolute_cap, {7, :day}`).
2. **Reuse-detection = Design B (family table), full issue now** — reuse gated in `verify_claims` on
   `family.current_jti` (not at refresh — see Phase 2 critical note).
3. Gates run with `SKIP_VISION=1` (auth/DB change, no vision surface — no Modal spend).

## Dependencies
#173 (refresh), #124 A2 (revocation), #174 (jwt trigger). Agents: security-agent + database-agent.
Same epic branch (`feat/124-e2e-auth`).
