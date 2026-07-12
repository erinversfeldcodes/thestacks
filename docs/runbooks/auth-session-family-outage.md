# Runbook: Auth session-family gate outage (fail-closed lockout)

**Severity:** P1 (authentication outage — users cannot make authenticated requests)
**Owner:** Platform operator / on-call
**Last reviewed:** 2026-07-11

---

## When to use this runbook

Use this when **authenticated requests are broadly failing with 401** across
many/all users at once, especially shortly after a deploy, a migration, or a
database incident affecting the `op` schema.

The trigger is the Issue #179 session-family reuse-detection gate. Every
authenticated request runs `Stacks.Accounts.check_token_family/3` (invoked from
`Stacks.Accounts.Guardian.verify_claims/2`), which reads
`op.auth_token_families` by primary key. That gate is deliberately
**fail-closed**: if the lookup raises (table missing, permission revoked,
connection pool exhausted, corrupt row), it logs and returns
`{:error, :family_check_failed}`, which the pipeline maps to **401**. This is the
correct security posture (never fail *open* into an unauthenticated request), but
it means a fault in that one table/query becomes a **fleet-wide auth outage**.

Symptoms:

- A spike in `401` on endpoints behind the `:authenticated` pipeline, affecting
  tokens that were working moments ago (not just expired ones).
- Application logs contain `check_token_family failed (failing closed): ...`
  (logged at `error` level from `Stacks.Accounts.check_token_family/3`).
- Login itself may also fail: `login/2` is **fail-closed** on family creation —
  if `open_token_family/1` cannot insert, the just-minted token is revoked and
  the request returns `500 internal_error`.

If the 401s are limited to genuinely expired/revoked tokens, or to a single user
who was force-logged-out, this is **not** an outage — see "Not this runbook".

---

## Diagnosis (fastest first)

1. **Is the table reachable?** Against the affected environment's DB:
   ```sql
   SELECT count(*) FROM op.auth_token_families;
   ```
   - Error / relation does not exist → the migration
     `20260711000000_create_auth_token_families` did not run (or ran against the
     wrong DB / was rolled back). Go to **Mitigation A**.
   - Permission denied → the `stacks_app` role lost its grant. **Mitigation B**.
   - Slow / times out → DB overload / pool exhaustion. **Mitigation C**.

2. **Check the app logs** for the exact exception behind the fail-closed:
   ```
   fly logs -a <core-app> | grep "check_token_family failed"
   ```
   The `inspect(error)` payload names the cause (`Postgrex.Error`,
   `DBConnection.ConnectionError`, `Ecto.QueryError`, etc.).

3. **Confirm the grant** (Mitigation B suspicion):
   ```sql
   SELECT has_table_privilege('stacks_app', 'op.auth_token_families', 'SELECT');
   ```
   `f` → the grant is missing.

4. **Recent change?** Correlate with the last deploy/migration. A partial deploy
   (new code that queries the table, old DB without the migration) is the most
   common cause.

---

## Mitigation

### A. The table is missing (migration didn't apply)

Run the pending migrations against the affected DB:
```bash
# On the release image (production/preview):
<app> eval "Core.Release.migrate()"
# or locally against the target: DATABASE_URL=... mix ecto.migrate
```
Verify `SELECT count(*) FROM op.auth_token_families;` now succeeds. Auth
recovers immediately (the gate stops raising). See also
`migration-recovery.md`.

**Root cause to fix:** deploy ordering — the code that reads
`op.auth_token_families` must not go live before its migration. Ensure the
release runs migrations before serving traffic.

### B. Grant missing on `stacks_app`

Re-apply the grant (idempotent, mirrors the migration):
```sql
GRANT INSERT, SELECT, UPDATE, DELETE ON op.auth_token_families TO stacks_app;
```
(`stacks_dbt` must remain *un*granted — auth session data must never reach the
warehouse role.)

### C. DB overload / pool exhaustion

The gate adds **one indexed PK lookup per authenticated request**. Under a DB
incident this is one more query competing for connections.
- Follow `neon-outage.md` / scale the pool / shed load.
- The gate recovers on its own once the DB is healthy again — no code change
  needed.

### D. Emergency bypass (LAST RESORT — reduces security)

If auth must be restored *before* the DB is fixed and you accept the security
regression (no reuse-detection / stale rotated tokens accepted until fixed):
the gate only engages for tokens carrying a `family_id` claim (the `is_binary`
branch in `Stacks.Accounts.Guardian.verify_claims/2`). A hotfix that makes
`check_token_family/3` return `:ok` on `:family_check_failed` (fail **open**)
would restore auth at the cost of the #179 protections. **Do not do this
unless** the alternative (total auth outage) is worse and you have sign-off;
revert it the moment the DB is healthy. Prefer Mitigations A–C.

---

## Verify recovery

- `SELECT count(*) FROM op.auth_token_families;` succeeds.
- A fresh login returns a token AND a follow-up authed request (e.g.
  `GET /api/auth/me`) returns 200.
- The `check_token_family failed` error log stops.
- 401 rate returns to baseline.

---

## Not this runbook

- **Single user force-logged-out after a suspicious event** — expected: reuse
  was detected and the family was burned (multi-tab / stolen-token response).
- **Everyone re-prompted to log in after ~7 days** — expected: the absolute
  session cap (#179) forces re-authentication; not an outage.
- **A user logged out on all devices after a password change** — expected:
  password change revokes all sessions by design.
- **Expired tokens 401ing** — normal token expiry, not the family gate.

---

## Related

- Issue #179 (absolute session cap + refresh-token family reuse-detection).
- `migration-recovery.md`, `neon-outage.md`, `manual-rollback.md`.
- Design: `docs/agents/standards/security.md`; the gate lives in
  `apps/core/lib/stacks/accounts/guardian.ex` (`verify_claims/2`) and
  `apps/core/lib/stacks/accounts.ex` (`check_token_family/3`).
