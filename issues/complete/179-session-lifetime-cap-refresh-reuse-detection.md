# Issue #179: Absolute session-lifetime cap + refresh-token reuse detection

## Summary
#173's proactive silent renewal turned the 8h access token into a **sliding session** with no
absolute lifetime cap and no refresh-token-family/reuse detection. Two consequences: (1) an active
session can be renewed indefinitely — there is no "re-authenticate after N days" bound; (2) a
stolen-then-silently-renewed token survives even the *victim's own logout*, because logout revokes
only the victim's current `jti`, not the attacker's rotated chain. Add an absolute cap and rotation
reuse-detection so a session is bounded and a logout/compromise kills the whole chain.

## User Stories
None directly — auth session-lifecycle hardening (builds on US-14.3.2 / #173).

## Goal
A session has a bounded total lifetime regardless of renewal, and a rotation chain is tracked so
that (a) reuse of an already-rotated token revokes the whole family, and (b) "log out everywhere" /
password change invalidates every token in the chain.

## Scope Check
- Touches `Guardian`/`AuthController.refresh` + `op.guardian_tokens` (a family/session id + original
  issue time) + possibly a migration. One concern (session bounding). Split the cap and the
  reuse-detection into two phases if it exceeds ~300 LOC.

## Wiring
- [x] Implementation only (auth backend). No new user-facing surface (a hard cap does force re-login,
  which the #173 interceptor already handles).

## Technical Requirements
1. **Absolute lifetime cap:** record the session's original issue time (or a `session_started_at`) so
   `/api/auth/refresh` refuses to renew past a configurable cap (e.g. 7 days) → 401 → the #173
   interceptor sends the user to `/login`. The cap must survive rotation (carry it in claims / the
   guardian_tokens family row, not reset on each refresh).
2. **Rotation-chain / reuse detection:** tag each token with a session/family id; on refresh, if a
   token that was ALREADY rotated is presented again (reuse), revoke the entire family (classic
   refresh-token-reuse response). Coordinate with guardian_db + #124 A2 (revocation) + #174 (jwt
   nulled).
3. **Revoke-all:** logout / password change should revoke every token in the user's family/chain, not
   just the current `jti`.

## Reviewer Context
- #173 refresh rotates via `Guardian.revoke(old)` + `encode_and_sign(new)` — there is currently no
  link between the old and new rows beyond `sub`. Reuse-detection needs an explicit family id.
- `op.guardian_tokens` is guardian_db's table (hand-migrated, not proto-managed); #174 added a
  `BEFORE INSERT OR UPDATE` trigger nulling `jwt` — any new column must coexist with it.

## Test Audit
_Compact — auth/DB security hardening. Green when the cap + reuse-detection are enforced and tested._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 2 Auth guards / 3 DB **(SECURITY)** | yes | ❌ refresh past the cap → 401; reused rotated token → whole family revoked; logout revokes the family. Validation: ExUnit against the real guardian_tokens (unit) + a `:deployed_only` check that a capped/reused token is rejected on a live preview. |
| 1,4–13 | no | n/a — no app-data/US/frontend surface (the forced re-login reuses #173's interceptor) |

## Definition of Done
- [ ] Refresh past the absolute cap → 401 (bounded total session lifetime, cap survives rotation)
- [ ] Reuse of an already-rotated token revokes the whole family
- [ ] Logout / password change revokes every token in the family, not just the current jti
- [ ] Every behaviour has a validation path — ExUnit (unit) + a `:deployed_only` live-stack check that a capped/reused token is rejected on a real preview
- [ ] `just verify` passes
- [ ] Test audit (embedded) is GREEN

## Dependencies
- #173 (silent renewal / refresh), #124 A2 (revocation), #174 (guardian_tokens.jwt trigger). Same epic
  branch or a fast-follow.

## Agent Assignment
security-agent + database-agent.

## Progress Notes
- 2026-07-10: Filed from #173's PE gate (P2). Silent renewal made the session sliding with no absolute
  bound and no reuse-detection; this bounds and hardens it.
