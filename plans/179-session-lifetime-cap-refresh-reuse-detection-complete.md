# Issue #179 — Complete

**Issue**: #179 — Absolute session-lifetime cap + refresh-token reuse-detection + revoke-all
**Branch**: `179-session-lifetime-cap-refresh-reuse-detection` (off `feat/124-e2e-auth`)
**Completed**: 2026-07-11
**Agents**: security-agent (P1, P2b, GDPR), database-agent (P2a) · **Revision cycles**: 1 (review nits) + GDPR/runbook fold-in

## What shipped
Hardened the session lifecycle #173's silent renewal left unbounded.

**Absolute cap (7 days, configurable):** `build_claims` stamps a signed `sst` session-start anchor at
login; `refresh/2` carries it forward unchanged (`Map.put_new`) so the cap does not reset on renewal;
refresh past the cap → 401 (the #173 interceptor routes to /login). Legacy tokens with no `sst` are
bound from now, not locked out.

**Refresh-token families + reuse-detection (Design B):** new `op.auth_token_families` (family_id PK,
user_id, current_jti, session_started_at, revoked_at). Login opens a family (fail-closed); refresh
advances `current_jti` (lazy-create for legacy sessions). The reuse gate is `verify_claims` — which
runs on EVERY authed request and, verified against `deps/guardian` (`guardian.ex:641` verify_claims
BEFORE `:642` on_verify), fires even though guardian_db deletes the old row on rotation: a token whose
`jti != family.current_jti` is REUSE → the whole family is revoked (`revoked_at` + `destroy_by_sub`
burns every session). Idempotent, fails closed to 401 (never 500), with a `user_id == sub` ownership
guard. **logout** revokes the family (kills an attacker's rotated chain sharing the victim's family);
**password change** revokes ALL the user's sessions; the token sweep prunes dead families; **GDPR
erasure** now deletes the user's families + guardian_tokens inside the erasure transaction.

## Known / accepted
A benign multi-tab request using the just-rotated token is seen as reuse → spurious logout. Intended
strict posture for #179; softened by a grace window in **#180**.

## Gate record
- 2A test-first each phase (P1 cap, P2a family+plumbing, P2b reuse gate + revoke) — RED→GREEN.
- 2C: **security-reviewer APPROVE** (no P0/P1; no fail-open, no cap-bypass; claims signature-protected;
  ordering verified) + **database-reviewer APPROVE** (migration/grants/indexes/queries sound). Both P2
  nits fixed: dropped the dead `current_jti` index; added the `user_id == sub` ownership guard.
- 2B-i `just verify`: **exit 0** (re-run after nit fixes). **2295 tests, 0 failures.**
- 2B-iia fresh-DB: migrate clean (only PK + user_id index; current_jti correctly absent).
- **2B-iii Deploy-Preview + live check: PASS** — deploy succeeded on real Fly + Neon preview
  (migration applied live, app healthy; SKIP_VISION=1 → no Modal spend). **Live reuse-detection over
  HTTP against the preview PASSED**: login→refresh (rotation)→current token 200 (no false revoke)→
  replayed rotated token 401 (reuse)→current token 401 (family burned). Stronger than the planned
  `sst`-DB-read (which is unit-covered); the preview Neon URL lives in the staging project and the
  ExUnit `:deployed_only` DB-read was skipped in favour of the HTTP reuse proof.
- 2F PE: folded into the security review (security-critical; fail-closed, bounded, no lockout of valid
  sessions confirmed).

## Folded in (reviewer findings, user-approved)
- **GDPR erasure revokes sessions** (`deletion.ex`): a `Multi.run(:revoke_sessions, ...)` step deletes
  the user's `op.auth_token_families` + `op.guardian_tokens` rows on the erasure transaction's repo
  (atomic; full removal, not just mark-revoked). Test proves no rows survive erasure. Closes the gap
  where an erased user's token stayed valid up to 8h.
- **Ops runbook** `docs/runbooks/auth-session-family-outage.md` (P1) — the fail-closed gate means a
  fault in `op.auth_token_families` becomes a fleet-wide auth outage; symptoms, diagnosis, mitigations
  A–D (incl. an emergency fail-open bypass of last resort), recovery.

## Files (Elixir/proto/docs; generated excluded)
config.exs · accounts.ex · accounts/auth_token_family.ex · accounts/guardian.ex ·
workers/guardian_token_sweep_job.ex · stacks_web/controllers/auth_controller.ex ·
stacks_web/controllers/user_settings_controller.ex · gdpr/deletion.ex ·
priv/repo/migrations/20260711000000_create_auth_token_families.exs ·
docs/runbooks/auth-session-family-outage.md · + tests (accounts, auth_controller, user_settings,
guardian_token_sweep_job, guardian_jwt_deployed, gdpr/deletion).

## Commit sequence (3 commits on this branch)
1. `chore:` SKIP_VISION flag (`scripts/deploy-stack.sh`, `e2e/tests/upload.spec.ts`) — separate infra.
2. `feat(#179):` session cap + family reuse-detection (core — the 13 Elixir/migration/test files).
3. `feat(#179):` GDPR erasure revokes sessions + the ops runbook (`deletion.ex`, `deletion_test.exs`,
   the runbook).

## Batch
Follow-up #4 of #178–182 complete (order 181 → 178 → 182 → 179 → 180, per-issue gates). Next & last:
**#180** (multi-tab / in-flight rotation race → grace window; softens #179's accepted false-positive).
