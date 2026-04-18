# Issue #138: Break-glass tooling for production data access

## Summary
Close all direct-read paths into the production Neon branch's `op.*` and `audit.*` schemas. Route every human-initiated read of user data (or data that could be used to reverse-engineer user data / usage patterns) through purpose-built, MFA-gated, fully-audited tooling. Expose nothing to direct `psql`, Neon console SQL, MCP agents, or `fly ssh console` Elixir shells.

## User Stories
N/A (platform / security).

## Goal
A real user can trust that nobody — operator, contractor, agent, or attacker with stolen credentials — reads their data or infers their usage patterns without an append-only audit record being created synchronously with the access.

## Scope Check
Exceeds the 300-LOC limit. Intentional; coherent security posture change. Split into phases A/B/C below so each phase can ship independently and land before real user signups require the full stack.

## Wiring
- [x] User-facing only indirectly (operator-facing admin endpoints + CLI).
- [x] Requires policy runbook landed alongside Phase A.

## Principle

> **No direct reads of user data or reverse-engineerable data. All such access goes through purpose-built break-glass tooling with strict auditing.**

"User data or reverse-engineerable" covers effectively all of `op.*` and `audit.*`:

| Category | Tables |
|---|---|
| Direct PII | `op.users`, `op.uploaded_images`, `op.event_log`, `audit.audit_log` |
| Behavioral | `op.bookshelves`, `op.bookshelf_placements`, `op.bookshelf_placement_history`, `op.listings`, `op.offer_threads`, `op.offer_messages`, `op.transactions` |
| De-anonymizable aggregates | any row count grouped by `user_id` or email domain; upload timing distributions; purchase-pattern aggregates from `wh.*` marts |
| Safe without break-glass | `op.schema_migrations`, `op.authors`, `op.books`, `op.book_editions`, `op.bookstores`, reference-data marts in `wh.*`, Postgres system catalogs |

Default is restricted. Reference-only tables are the documented exception.

## Current exposure (pre-Phase-A)

Four paths let a human read restricted data today, none of them app-audited:

1. **Neon API key access via MCP or Neon console.** Anyone holding `NEON_API_KEY` runs arbitrary SQL against any branch. Used extensively during Issue #136 for legitimate operator actions (TRUNCATE, metadata queries). No audit trail outside the session transcript.
2. **`psql` with the composed prod `DATABASE_URL`.** Operator pulls the URI from Fly secrets or reconstructs from the `STACKS_PROD_DB_*` GitHub Secrets and connects directly. No audit.
3. **`fly ssh console` → `/app/bin/core remote`.** Elixir remote shell, full `Core.Repo` access. Requires Fly auth but no app-level audit.
4. **Neon console UI.** Web UI for whoever's logged into the Neon account.

All four bypass `audit.audit_log`. Phase A+B+C below close them.

## Phase A — Admin API + mandatory MFA + full audit (target: before first real user signup)

### Deliverables

**Admin-only controller** — `StacksWeb.AdminController`, behind:
- Owner-role authentication
- TOTP MFA every session (session cap 30 min)
- Explicit `reason` field on every request (free-text, logged verbatim)
- Rate limiting (per operator, per endpoint)

**Purpose-specific endpoints** — no raw SQL surface:
- `GET /api/admin/users/by_email?email=...` — single user record
- `GET /api/admin/users/by_id?id=...`
- `GET /api/admin/audit_log?user_id=...&from=...&to=...` — audit trail for a specific user (for user inquiries or GDPR requests)
- `GET /api/admin/gdpr_export?user_id=...` — full personal data export (compliance)
- `POST /api/admin/gdpr_erase?user_id=...` — right to erasure; emits GDPR-erasure audit event
- `GET /api/admin/platform_stats` — aggregate counts only, no per-user dimensions
- `GET /api/admin/owner_tools/{narrow operational queries}` — each one added deliberately with a specific justified use case

Deliberately omitted:
- No "run arbitrary SQL" endpoint. Ever.
- No endpoint that returns behavioral aggregates broken down by user segment (unless the segment is large enough to be non-identifying — ~50 users per bucket minimum).

**Audit trail** — every call writes to `audit.audit_log`:
- Operator ID + session ID
- Endpoint + parameters
- Free-text reason from the request
- Row IDs or counts returned (not payload — we don't want the audit log itself to leak the data it records)
- Latency / success flag
- Source IP

Audit rows are append-only; the `audit.audit_log` schema already supports this. Add a check constraint or trigger preventing UPDATE/DELETE on the audit table (except via the existing GDPR-erasure path, which itself logs the erasure).

**Session hardening:**
- Session tokens bound to IP (session invalidates on IP change — accept some operator UX pain for integrity)
- No "remember me" on admin sessions
- Forced logout on every deploy (invalidate all admin sessions on app boot)

### DoD for Phase A
- Admin controller exists with MFA gate and audit logging
- At minimum the four GDPR-critical endpoints (by_email, by_id, audit_log, gdpr_export, gdpr_erase) implemented and tested
- Every Phase A endpoint has an E2E test that verifies an audit row is created with all required fields
- Session IP binding works; test that session invalidates on IP change
- Runbook `docs/runbooks/prod-data-access.md` documents the admin API as the ONLY allowed non-break-glass access path
- `NEON_API_KEY` scope narrowed to branch-management-only (no SQL access)

## Phase B — Signed, short-lived credentials for direct SQL (target: within 3 months of Phase A)

Phase A covers known queries. Phase B covers the "something weird happened and I need to poke around" case without leaving a permanent backdoor.

### Deliverables

**`stacks-break-glass` CLI** — runs locally or in a Fly-hosted admin container:

Flow:
1. Operator runs `stacks-break-glass --reason "investigating bug #456"`
2. CLI prompts for MFA + owner credentials
3. CLI authenticates against the app's admin endpoint (same auth as Phase A)
4. App calls Neon API to create a 5-minute-TTL role with:
   - Read-only access (`stacks_auditor` role — no INSERT/UPDATE/DELETE grants except via GDPR erasure path)
   - Password scoped to operator's current public IP
5. App writes `audit.audit_log` row: break-glass opened, operator, reason, issued-to-IP, TTL
6. CLI prints the short-lived `DATABASE_URL` to stdout
7. Operator uses it with `psql`. Every query flows through `pgaudit` → Postgres logs → streamed to an immutable R2 bucket (tamper-evident with SHA signatures)
8. Role auto-drops at TTL; CLI writes `audit.audit_log` row: break-glass closed
9. If operator needs more than 5 minutes, they re-initiate (which re-logs, re-prompts MFA, re-states reason)

**pgaudit on the prod branch:**
- `pgaudit.log = 'read, write'`
- `pgaudit.log_catalog = off` (don't log schema inspection queries — noise)
- `pgaudit.log_relation = on` (log tables touched, for correlation)

**Postgres log streaming:**
- Neon log export → R2 bucket `thestacks-audit-logs` with object-lock enabled (WORM)
- Retention: 7 years (GDPR erasure request record-keeping)
- SHA-256 of each log file recorded in `audit.audit_log` for tamper detection

### DoD for Phase B
- CLI + associated admin endpoint implemented
- pgaudit enabled on prod Neon branch and confirmed logging reads/writes with operator role attribution
- R2 streaming pipeline operational with object-lock
- Test: operator opens break-glass, runs a query, closes; confirm log row in R2 matches pgaudit output, SHA recorded in `audit.audit_log`
- Phase A admin controller explicitly rejects arbitrary-SQL endpoints (static-analysis rule in CI)
- `psql` with old-format `DATABASE_URL` (the always-on prod secret) blocked at Neon via IP allowlist

## Phase C — Defense in depth (target: ongoing, no hard deadline)

Assumes Phases A + B are live. Adds layers so even a credential breach doesn't produce a clean data leak.

### Deliverables

**Row-level security (RLS) on all `op.*` tables that reference `user_id`:**
- Default-deny policies
- Policies keyed on `current_setting('app.current_user_id')` which app sets via `SET LOCAL` at the start of every request transaction
- `stacks_auditor` break-glass role bypasses RLS (with mandatory pgaudit trail)

**Column-level encryption expansion:**
- Current: `CloakEcto` encrypts the `audit.audit_log` metadata column and a few specific PII columns
- Expansion: encrypt emails at rest (searchable via HMAC blind index), encrypt display names, encrypt bookshelf names (if private), encrypt listing descriptions
- Keyring rotation via `CLOAK_KEY` primary + deprecated keys list

**App-user context on every connection:**
- `Stacks.Repo` wrapper that calls `SET LOCAL app.current_user_id = '<uuid>'` + `SET LOCAL app.request_id = '<uuid>'` at start of every transaction
- Propagates through to pgaudit logs, so even app-driven queries carry user attribution at the DB level
- Benefit: if the app-level audit log is ever unavailable or tampered with, pgaudit logs can reconstruct who did what

**Break-glass credential escrow:**
- MFA enrollment managed through an operator-side registry (Yubikey recommended, TOTP acceptable)
- Loss-of-access recovery requires a second operator's co-signature (2-of-N escrow) — no single person can grant themselves break-glass access
- Prevents insider threat via sole-operator credential theft

**Supplementary access-monitoring:**
- Anomaly detection on `audit.audit_log` — alerts when an operator reads an unusually large number of user records in a short window, or queries outside business hours, or uses break-glass outside an active incident
- Weekly summary email to operator(s) listing all break-glass opens from the past week

### DoD for Phase C
- RLS policies in place on all `op.*` PII-bearing tables, with E2E tests that confirm bypass requires the `stacks_auditor` role
- Emails, display names, and other identified PII columns encrypted at rest via `CloakEcto`
- App sets `app.current_user_id` per-transaction; pgaudit logs include it
- Two-of-N break-glass escrow documented and tested
- Anomaly detection job + operator summary emails operational

## Reviewer Context

- Builds on Issue #136's release workflow — the `audit.audit_log` shape and `Stacks.Audit` module already exist.
- `CloakEcto` already handles encryption for a subset of columns; expansion is additive, not restructuring.
- Neon supports pgaudit as of 2024; no extension approval needed.
- IP-restricted Neon passwords are supported via the Neon API.
- The `stacks_app`, `stacks_dbt`, `stacks_readonly` roles from the `CreateDbRoles` migration stay; Phase B adds `stacks_auditor` as a sibling with its own gated lifecycle.

## Definition of Done
- [ ] Phase A shipped and verified in prod before the first real user signup.
- [ ] Phase B shipped within 3 months of Phase A; direct `psql` access via always-on `DATABASE_URL` becomes physically impossible (Neon IP allowlist).
- [ ] Phase C incremental — RLS first (within 6 months of Phase B), then column encryption, then anomaly detection.
- [ ] Corresponding runbook `docs/runbooks/prod-data-access.md` kept current at each phase; drift between doc and reality is itself a policy violation.
- [ ] Quarterly review of `audit.audit_log` patterns — confirm no access is happening outside the policy-allowed paths.

## Dependencies
- Issue #136 (this PR) establishes the Fly production app and core deploy workflow.
- No code dependencies for Phase A. Phase B depends on `pgaudit` being enabled (Neon console toggle). Phase C depends on Phase B's `stacks_auditor` role.

## Agent Assignment
security-agent (policy + audit design), elixir-agent (admin controller + RLS), platform-agent (pgaudit + Neon API integration + CLI), database-agent (RLS policies + role grants).

## Progress Notes
2026-04-18: Issue created during Issue #136 work. Phases A/B/C documented. Implementation deferred — #136 is the priority for now.
