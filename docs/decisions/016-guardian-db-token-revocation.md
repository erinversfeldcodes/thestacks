# ADR 016: Server-Side JWT Revocation via Guardian.DB

**Status:** Accepted
**Date:** 2026-07-09
**Deciders:** Platform owner
**Technical area:** Authentication, session management

---

## Context

Issue #124 (A2) requires that logout **invalidate a session server-side**. Before
this change, The Stacks issued stateless HS256 JWTs (Guardian, no `guardian_db`):
a token was verifiable purely from its signature and expiry claim. That has a
hard limitation — **a stateless HS256 token cannot be revoked.** Once signed, it
is valid until it expires no matter what the server does. "Logout" could only
discard the token on the client; a copy of the token (leaked, cached, or held by
a malicious client) kept working until natural expiry.

For a marketplace phase with real user accounts and sellers, an un-revocable
session is unacceptable: a compromised or shared token must be killable on
demand, and logout must mean logout.

The token TTL was also effectively unbounded in practice (long-lived), which — once
tokens are DB-tracked — would let the tracking table grow without a natural expiry
to sweep against.

---

## Decision

**Adopt `guardian_db` to persist and presence-check access tokens, making
`Guardian.revoke/1` (and logout) actually invalidate a live token.**

Concretely:

- **Storage.** A new `op.guardian_tokens` table
  (`apps/core/priv/repo/migrations/20260708120000_create_guardian_tokens.exs`)
  whose column shape matches `Guardian.DB.Token`'s Ecto schema: string `jti`
  primary key, `sub`/`exp`/`jwt`/`claims`, and explicit `inserted_at`/`updated_at`
  (added by hand because this project globally rewrites `timestamps()` to
  `created_at`, which `Guardian.DB` does not expect). Indexes on `sub` (revoke-all
  / sweep filtering) and `exp` (reaper range delete).
- **Hooks.** `Stacks.Accounts.Guardian`
  (`apps/core/lib/stacks/accounts/guardian.ex`) delegates the four
  `Guardian.DB` lifecycle callbacks:
  - `after_encode_and_sign/4` — INSERT the token row on sign
    (`guardian.ex:69`).
  - `on_verify/3` — presence-check the row on every verify (`guardian.ex:76`).
  - `on_refresh/3` — swap old row for new (`guardian.ex:83`).
  - `on_revoke/3` — DELETE the row on revoke / logout (`guardian.ex:91`).
- **TTL.** Access tokens live **8 hours** (`config :core, Stacks.Accounts.Guardian, ttl: {8, :hours}` —
  `apps/core/config/config.exs:91`). This bounds every session and guarantees the
  reaper has expired rows to purge. **No refresh token** is issued; a refresh flow
  is deferred to #173.
- **Scope.** Only `"access"` tokens are tracked
  (`config :guardian, Guardian.DB, token_types: ["access"]` —
  `config.exs:103`). Admin `"admin_session"` tokens are **excluded**; they carry
  a `bid` (boot_id) claim and are revoked out-of-band via `boot_id` invalidation +
  the `admin_sessions` table (see `Stacks.Accounts.Guardian.verify_claims/2`,
  `guardian.ex:46`).
- **Sweeper.** `Stacks.Workers.GuardianTokenSweepJob`
  (`apps/core/lib/stacks/workers/guardian_token_sweep_job.ex`) runs daily via the
  Oban crontab (`{"0 0 * * *", ...}`, `config.exs:72`) and calls
  `Guardian.DB.Token.purge_expired_tokens/0` — a single indexed
  `DELETE ... WHERE exp < now()` — so expired-but-not-logged-out tokens don't
  accumulate as permanent tombstones.
- **Logout.** `AuthController.logout/2`
  (`apps/core/lib/stacks_web/controllers/auth_controller.ex:96`) calls
  `Guardian.revoke/1` on the current token, deleting its `op.guardian_tokens`
  row.

---

## Alternatives considered

| Option | Why not |
|--------|---------|
| **Stateless HS256 + short TTL only** (no DB tracking) | Simplest and keeps auth fully CPU-bound (no DB dependency on the verify path), but does **not** satisfy A2: a token remains valid until expiry, so logout cannot invalidate it and a leaked token stays live. A short TTL shrinks the exposure window but never closes it, and short TTLs without a refresh flow force frequent re-login. |
| **Custom ETS + Postgres deny-list** (from the plan's Open Questions) | An in-memory ETS revocation cache backed by Postgres would keep the common-case verify fast while still supporting revocation. Rejected as premature: it reintroduces cache-coherency complexity (multi-node invalidation, cold-start warming, ETS↔Postgres drift) for a single-node deployment, and `guardian_db` is a maintained, well-trodden library that does exactly this. ETS caching in front of `on_verify` remains a future optimisation if the per-request SELECT becomes a bottleneck. |

---

## Consequences

**Positive:**
- Logout and `Guardian.revoke/1` genuinely invalidate a session — A2 satisfied.
- Sessions are hard-bounded at 8h; the sweeper keeps the tracking table small.
- Admin sessions keep their existing stronger, boot-scoped revocation semantics.

**Negative / trade-offs (auth is now stateful):**
- **Per-request DB verify.** Every authenticated request performs a PK-indexed
  `SELECT` on `op.guardian_tokens`. Auth is no longer purely signature
  verification; it now has a DB round-trip on the hot path.
- **Availability coupling.** A Neon/Postgres outage now 401s **all** authenticated
  traffic, not just endpoints that touch the DB directly. Auth availability is
  now bounded by DB availability.
- **Login depends on INSERT.** If the `op.guardian_tokens` INSERT fails at sign
  time, `encode_and_sign` fails and the user cannot log in.
- **Raw JWT at rest.** The full JWT is stored in the `jwt` column. This
  raw-token-at-rest exposure is tracked separately as **#174**. (The
  `stacks_dbt` role is deliberately not granted access to the table to avoid
  widening the blast radius of a warehouse-credential compromise.)
- **Force-logout on deploy.** Any deploy that introduces or resets this table
  invalidates all pre-existing sessions (tokens with no matching row fail
  `on_verify` → 401 → users must re-login). Expected, not a regression — see the
  deploy note in `docs/runbooks/migration-recovery.md`.

---

## Related

- Issue #124 (A2) — server-side JWT revocation.
- Issue #173 — refresh-token flow (deferred).
- Issue #174 — raw-JWT-at-rest hardening.
- `docs/technical-architecture.md` — "Server-side token revocation (stateful auth)".
- `docs/runbooks/migration-recovery.md` — deploy force-logout + rollback lockstep.
- `docs/capacity-model.md` — per-request `op.guardian_tokens` SELECT on the auth path.
