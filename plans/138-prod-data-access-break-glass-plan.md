# Plan: Break-glass tooling for production data access (Phase A)
**Issue**: #138
**Created**: 2026-05-04
**Status**: Approved

## Context

Close every direct-read path into the production Neon branch's `op.*` and `audit.*` schemas. Route every human-initiated read of user data — or data that could reverse-engineer it — through purpose-built, MFA-gated, fully-audited Phoenix endpoints. Phase A delivers the in-app admin layer and operational lockdowns that make Phase B's signed short-lived credentials and Phase C's RLS feasible. Target: ship before the platform's first real user signup.

## Research Summary

**What exists today** (audited 2026-05-04):
- `audit.audit_log` table + `Stacks.Audit.log/3` already encrypt metadata via Cloak and hash IPs. Existing schema lacks `endpoint`, `latency_ms`, `success`, `row_count`, `operator_session_id`. **No DB-level UPDATE/DELETE prevention** — only an application-layer convention.
- Guardian-based JWT auth with infinite-TTL stateless tokens. `:require_owner` pipeline already gates `/api/metrics/*` and `/api/admin/{sources,partners}`. No MFA, no IP binding, no per-deploy revocation.
- DB roles `stacks_app`, `stacks_dbt`, `stacks_readonly` exist via migration `20260305000020_create_db_roles.exs`. **Prod app currently connects as `neondb_owner`**, bypassing all grant discipline.
- Rate limiter has per-user buckets (`:upload`, `:social`); no `{user_id, endpoint}` keying yet.
- No TOTP library in `mix.lock`. `Stacks.Vault` (Cloak) already in production for `audit.audit_log.metadata`.
- `probe-production.sh` reuses `PROD_OWNER_*` credentials — explicit comment in `deploy-production.yml` flags Issue #138 as the fix.
- User-facing GDPR endpoints (`/api/gdpr/{export,account,consent}`) exist; Phase A adds operator-on-behalf-of-user counterparts.

**Reusable foundations**: `Stacks.GDPR.Export`, `Stacks.GDPR.Deletion`, `Stacks.Admin.Metrics`, `Stacks.Audit`, `Stacks.Vault`. Phase A composes these behind a new auth pipeline, not a rewrite.

## Approach Options

- **Option A (chosen):** Four sequential sub-phases — foundations (audit schema + prober + DB trigger) → MFA + admin session → admin endpoints + audit middleware → hardening (DB role switch, Neon scope, IP allowlist, runbook). One coherent `Stacks.Admin` context + single `StacksWeb.AdminController`. **Recommended.**
- **Option B:** Per-domain admin controllers (UserAdmin, AuditAdmin, GDPRAdmin, OwnerToolsAdmin). Cleaner separation but premature abstraction at current scope.
- **Option C:** Reuse existing user JWT with an `mfa_validated_at` claim — no separate admin token type. Mixes user/admin session semantics; forced-logout-on-deploy would impact users too.
- **Option D:** Defer TOTP, use deploy-time secret rotation as the human factor. Cuts ~30% of Phase A scope but contradicts the issue's explicit DoD.

## Resolved Open Questions

| # | Question | Decision |
|---|---|---|
| 1 | MFA recovery for sole operator | **Print one-time recovery codes at enrolment (Phase 2).** Phase C upgrades to 2-of-N escrow once multiple operators exist. |
| 2 | IP binding granularity | **Exact match.** Admin sessions are short-lived incident-response; tighter binding is safer. |
| 3 | MFA on existing owner routes | **Yes — all existing owner-role routes pass through the new admin auth pipeline.** "Prod data only visible on the site" requires uniform gating. |
| 4 | MFA storage | **New `op.user_mfa` table.** Cleaner separation; future-proof for hardware keys (Phase C); doesn't bloat `op.users`. |
| 5 | Forced-logout-on-deploy | **`boot_id` claim** baked into admin tokens at issue, checked by plug. Per-process, admin-only (user tokens unaffected). |
| 6 | Neon IP allowlist | **Pulled into Phase 4** (was Phase B). Operational change, no code; aligns with "direct DB access locked down" principle. |

## Phases

### Phase 1: Audit foundations + prober user + append-only trigger
**Objective**: Extend `audit.audit_log` to carry admin-call shape; enforce append-only at the DB layer; create a non-owner prober user so probe logs no longer leak the owner password.

**Agent(s)**: database-agent (lead), elixir-agent (Audit module + Release.seed_prober + GDPR multi GUC)

**Steps**:
1. **Proto-first schema change.** Add fields to `proto/stacks/internal/v1/audit.proto`: `endpoint` (string), `latency_ms` (int32), `success` (bool), `row_count` (int32), `operator_session_id` (string). Run `mix proto.sync` to regenerate the Ecto schema + dbt staging model.
2. **Migration `<ts>_extend_audit_log_columns.exs`.** Add the five columns as nullable (additive; existing rows survive). Update `Stacks.Audit.log/3` to accept and persist them via `:opts`.
3. **Migration `<ts>_audit_log_append_only_trigger.exs`.** Create a `BEFORE UPDATE OR DELETE` trigger on `audit.audit_log` raising an exception unless `current_setting('app.audit_gdpr_erasure', true) = 'true'`. Trigger applies to all roles (including `neondb_owner`).
4. **Update `Stacks.GDPR.Deletion`.** Inside the existing `Ecto.Multi`, add a `Multi.run` step that issues `SET LOCAL app.audit_gdpr_erasure = 'true'` before any audit modification. Confirm rollback clears the GUC.
5. **`Stacks.Release.seed_prober/0`.** New idempotent function (mirrors `seed_prod/0`) creating `prober@thestacks.app` with role `user`, `email_confirmed: true`, password from `STACKS_PROBER_PASSWORD` env. Bookshelves not seeded (probe doesn't need them).
6. **Wire prober into deploy.** `deploy-production.yml`: add `STACKS_PROBER_EMAIL` / `STACKS_PROBER_PASSWORD` env from secrets; rewire `PROBE_SEED_*` to point at prober secrets; add a `seed_prober` invocation alongside `seed_prod` in the deploy step.

**Test Command**: `nix develop --command mix test apps/core/test/stacks/audit_test.exs apps/core/test/stacks/release_test.exs apps/core/test/stacks/gdpr/deletion_test.exs`

**DoD Items** (mapped to issue):
- [ ] Audit table extended with `endpoint`, `latency_ms`, `success`, `row_count`, `operator_session_id` (nullable, additive) — verifies via Ecto schema test
- [ ] DB trigger blocks UPDATE/DELETE on `audit.audit_log` even for `neondb_owner` unless GDPR GUC set — verified by integration test running raw SQL UPDATE/DELETE
- [ ] `Stacks.Release.seed_prober/0` exists, idempotent, creates non-owner user with confirmed email
- [ ] `deploy-production.yml` references `STACKS_PROBER_EMAIL` / `STACKS_PROBER_PASSWORD`, no longer leaks owner password into `probe-production.sh`
- [ ] dbt staging model `stg_audit_log` regenerated and reflects new columns
- [ ] Working tree clean for `mix proto.sync --check`

---

### Phase 2: TOTP/MFA + admin session pipeline
**Objective**: Stand up TOTP enrolment + verification, recovery codes, and a separate admin Guardian token with 30-min TTL, IP-bound, MFA-validated, boot_id-stamped claims.

**Agent(s)**: elixir-agent (lead), security-agent (review of crypto and session lifecycle)

**Steps**:
1. **Add `nimble_totp` dep** to `apps/core/mix.exs`.
2. **Migration `<ts>_create_user_mfa.exs`.** New `op.user_mfa` table: `user_id` (FK, unique, ON DELETE CASCADE), `secret` (bytea — Cloak-encrypted), `enrolled_at`, `recovery_codes` (bytea — Cloak-encrypted JSON array), `recovery_codes_remaining` (int).
3. **`Stacks.Accounts.MFA` context.** Functions: `enrol/1` (returns provisioning URI + recovery codes), `confirm_enrolment/2` (verifies first code), `verify/2` (TOTP code, with constant-time comparison), `consume_recovery_code/2`, `disabled?/1`.
4. **`Stacks.Accounts.AdminGuardian`.** New Guardian module (separate from `Stacks.Accounts.Guardian`) with admin token type. Claims: `sub` (user_id), `mfa_validated_at` (unix ts), `client_ip` (exact string), `boot_id` (UUID from process state), `exp` (issued + 30 min). No refresh.
5. **`Stacks.BootId`.** Process module set on app startup; exposes `current/0` returning the boot UUID. Reset per process boot = per deploy.
6. **`StacksWeb.MFAController`.** Endpoints: `POST /api/admin/mfa/enrol`, `POST /api/admin/mfa/confirm`, `POST /api/admin/mfa/challenge` (admin login: email + password + TOTP → admin JWT). Returns recovery codes as plaintext exactly once, on enrolment.
7. **Admin auth plug stack.** `StacksWeb.Plugs.AdminAuthPipeline` chaining: `Guardian.Plug.VerifyHeader` (admin-token-type) → `LoadResource` → `BootIdCheck` (claim must equal `Stacks.BootId.current/0`) → `IPBoundSession` (claim must equal extracted client IP, exact match) → `RequireMFAValidated` (`mfa_validated_at` must be within session TTL) → `RequireRole "owner"`.

**Test Command**: `nix develop --command mix test apps/core/test/stacks/accounts/mfa_test.exs apps/core/test/stacks_web/controllers/mfa_controller_test.exs apps/core/test/stacks_web/plugs/admin_auth_pipeline_test.exs`

**DoD Items**:
- [ ] `op.user_mfa` table created with Cloak-encrypted `secret` and `recovery_codes`
- [ ] `Stacks.Accounts.MFA` covers enrol, confirm, verify, recovery-code consumption — full unit-test coverage
- [ ] Recovery codes returned exactly once at enrolment; cannot be re-fetched
- [ ] `AdminGuardian` admin tokens carry `mfa_validated_at`, `client_ip`, `boot_id`, 30-min `exp`
- [ ] `BootIdCheck` plug rejects tokens with stale boot_id (test simulates restart)
- [ ] `IPBoundSession` plug rejects tokens with mismatched client IP (test sends from different IP)
- [ ] `RequireMFAValidated` plug rejects tokens older than session TTL
- [ ] No "remember me" surface on `/api/admin/mfa/challenge` — test asserts no refresh token in response

---

### Phase 3: Admin endpoints + audit middleware
**Objective**: Expose break-glass endpoints under `/api/admin/...`, wrap every admin call with reason-required + per-`{user_id, endpoint}` rate-limit + audit-row-on-success-and-failure, and route ALL existing owner routes through the same pipeline.

**Agent(s)**: elixir-agent (lead). Reviewer fan-out includes contract-reviewer (router + Ecto/proto changes).

**Steps**:
1. **`StacksWeb.Plugs.RequireReason`**. Rejects 422 if request body / query string lacks non-empty `reason`.
2. **Extend `StacksWeb.Plugs.RateLimiter`**. Add `:admin` bucket type keyed `{user_id, endpoint_path}`. Configurable limit (default 30/min per operator per endpoint).
3. **`StacksWeb.Plugs.AuditAdminCall`**. Wraps the response. Captures: operator user_id, session id from token, endpoint path, latency_ms, success bool, row_count (from controller assigns), source IP, free-text reason. Calls `Stacks.Audit.log/3` synchronously after response sent (cannot block the response on audit failure — audit failure logs an error but does not change response status).
4. **`StacksWeb.AdminController`**. Endpoints:
   - `GET /api/admin/users/by_email?email=...&reason=...` → single user
   - `GET /api/admin/users/by_id?id=...&reason=...`
   - `GET /api/admin/audit_log?user_id=...&from=...&to=...&reason=...` (paginated)
   - `GET /api/admin/gdpr_export?user_id=...&reason=...` → synchronous JSON export (reuses `Stacks.GDPR.Export.export_user_data/2`)
   - `POST /api/admin/gdpr_erase` body `{"user_id": "...", "reason": "..."}` → synchronous erasure (reuses `Stacks.GDPR.Deletion.delete_user_data/1`)
   - `GET /api/admin/platform_stats?reason=...` → aggregate counts only, no per-user dimensions
   - `GET /api/admin/owner_tools/...` namespace stub (no endpoints in Phase A; placeholder router scope ready for future targeted operator queries)
5. **Router rewire.** Move existing owner routes (`/api/metrics/*`, `/api/admin/sources`, `/api/admin/partners`) into the new `:admin_auth` pipeline. The `:require_owner` pipeline becomes a building block of `:admin_auth`, no longer used directly.
6. **Static analysis check (CI).** Add a Credo check or simple grep in `scripts/lint-elixir.sh` that fails CI if `StacksWeb.AdminController` ever calls `Repo.query/2` or `Ecto.Adapters.SQL.query/3` directly. Phase B's "no arbitrary SQL endpoint" rule starts here.

**Test Command**: `nix develop --command mix test apps/core/test/stacks_web/controllers/admin_controller_test.exs apps/core/test/stacks_web/plugs/{require_reason,audit_admin_call}_test.exs`. Plus E2E: `nix develop --command bash e2e/run.sh tests/admin_audit.spec.ts` (new spec).

**DoD Items**:
- [ ] All seven Phase A endpoints implemented (5 break-glass + platform_stats + owner_tools placeholder)
- [ ] Each endpoint enforces `reason` (422 if missing/blank) — controller test
- [ ] Each endpoint creates exactly one `audit.audit_log` row with all required fields populated — E2E test verifies audit row shape per endpoint
- [ ] Per-operator-per-endpoint rate limit returns 429 after threshold — controller test
- [ ] Existing owner routes (`/api/metrics/*`, `/api/admin/{sources,partners}`) require admin auth (MFA + reason + IP-bound) — pipeline integration test
- [ ] Static analysis check fails CI if admin controller introduces raw SQL — meta-test (commit a violation locally, confirm lint fails)
- [ ] `gdpr_erase` endpoint sets `app.audit_gdpr_erasure` GUC; trigger from Phase 1 allows the cleanup; non-erasure UPDATE/DELETE still blocked

---

### Phase 4: Hardening — prod role switch + Neon IP allowlist + Neon API key scope + runbook
**Objective**: Operationalise the lockdown so no remaining direct-DB path exists, and document the policy.

**Agent(s)**: platform-agent (lead — operational changes), security-agent (runbook review)

**Steps**:
1. **Prod app role switch.** Rotate `STACKS_PROD_DB_ROLE` GH secret from `neondb_owner` to `stacks_app`. `stacks_app`'s INSERT-only grant on `audit.audit_log` becomes binding (the trigger from Phase 1 stays as defence-in-depth even for owners). Verify a fresh prod deploy + warmup + the existing E2E suite all pass under reduced privileges.
2. **Neon API key scope narrowing.** Rotate `NEON_API_KEY` to a Neon-API-key scoped to project branch operations only — no SQL. Verify `deploy-production.yml`'s rollback action and `scripts/rollback-production.sh`'s Neon restore call still succeed under the narrower scope. Document in runbook.
3. **Neon IP allowlist.** Configure the prod Neon project to accept connections only from Fly's outbound IPs (operator action via Neon console or API). Direct `psql` from operator laptop becomes physically impossible. Document the allowlist in the runbook so operators know why their direct connection breaks.
4. **`docs/runbooks/prod-data-access.md`.** New runbook covering:
   - Allowed access paths (`/api/admin/...` only; existing site UI for owners; nothing else).
   - Disallowed paths (Neon SQL console, `psql`, `fly ssh ... /app/bin/core remote`, MCP server SQL, any other direct DB tool). For each, document why it's blocked and what to do instead.
   - MFA enrolment procedure for new owners.
   - GDPR erasure procedure (operator-initiated via `/api/admin/gdpr_erase`).
   - "What if the admin API doesn't cover my need?" → escalate, file an issue, do not break glass directly. Phase B will add the signed-credentials CLI for unforeseen cases.
5. **Cross-link from existing docs.** Update `docs/technical-architecture.md`'s "Authentication & API Security" and "Database Security" sections to reference the new admin pipeline and trigger. Update `docs/runbooks/secrets-rotation.md` with prober secrets + Neon API key scope.

**Test Command**: `nix develop --command bash test/platform/run_all.sh` (verifies workflow contract). Manual verification on staging: deploy with `stacks_app` role, run admin endpoint, confirm audit row written.

**DoD Items**:
- [ ] Prod app connects as `stacks_app` (not `neondb_owner`) — verified post-deploy by querying `current_user` via metrics endpoint
- [ ] `NEON_API_KEY` rotated to branch-management scope — verified by attempting a SQL call against the new key (expect 403)
- [ ] Neon IP allowlist active — verified by attempting `psql` from a non-Fly IP (expect connection refused)
- [ ] `docs/runbooks/prod-data-access.md` exists and lists every allowed/disallowed path
- [ ] `docs/technical-architecture.md` and `docs/runbooks/secrets-rotation.md` updated
- [ ] Issue #138 Phase A DoD checkboxes ticked at issue level

---

### Parallel Execution

**Independent phases**: None within Phase A. Phase 1's trigger must precede Phase 3's `gdpr_erase` (which depends on the trigger to enforce the GUC allowlist). Phase 2's auth pipeline must precede Phase 3's endpoints (which mount on it). Phase 4 must come last (operational lockdown should land after the alternative path works).

**Merge order**: Sequential — Phase 1 → 2 → 3 → 4. Each phase ships as a single PR / commit cluster; Phase 4 also touches GH secrets + Neon console (operator actions outside the repo).

## Open Questions

None. All decisions captured in the "Resolved Open Questions" table above.

## Integration Handoffs

- **Phase 1 → Phase 2**: Phase 2's MFA enrolment writes audit rows using the new columns from Phase 1. Phase 2 stalls if Phase 1's `Stacks.Audit.log/3` extension hasn't shipped.
- **Phase 1 → Phase 3**: Phase 3's `AuditAdminCall` plug uses the new audit columns. `gdpr_erase` endpoint relies on the trigger + GUC allowlist.
- **Phase 2 → Phase 3**: Phase 3's admin endpoints sit on `:admin_auth` pipeline from Phase 2. Endpoint controller tests need an MFA-validated admin token helper.
- **Phase 3 → Phase 4**: Phase 4's role switch happens against a deploy where Phase 3's audit middleware works under `stacks_app`'s INSERT-only grant. Verify before rotating the secret.
- **Phase A → Phase B (deferred)**: Phase B's break-glass CLI extends `Stacks.Audit` with `breakglass.opened`/`breakglass.closed` events; reuses Phase 2's MFA + IP-bound session pattern. Phase A leaves the namespace and pipeline shapes that Phase B can hook into without restructuring.
- **Phase A → Phase C (deferred)**: Phase C's RLS policies key on `current_setting('app.current_user_id')`. Phase A doesn't yet implement transaction-scoped GUC injection per request; that's a Phase C deliverable. Phase A's audit middleware records `user_id` at the application layer.

## Files to Touch (Researcher's exhaustive list — confirmed during planning)

**New** (~15 files):
- `apps/core/lib/stacks_web/controllers/admin_controller.ex`
- `apps/core/lib/stacks_web/controllers/mfa_controller.ex`
- `apps/core/lib/stacks/accounts/mfa.ex`
- `apps/core/lib/stacks/accounts/admin_guardian.ex`
- `apps/core/lib/stacks/boot_id.ex`
- `apps/core/lib/stacks_web/plugs/admin_auth_pipeline.ex`
- `apps/core/lib/stacks_web/plugs/{require_mfa_validated,require_reason,ip_binding,boot_id_check,audit_admin_call}.ex`
- `apps/core/priv/repo/migrations/<ts>_extend_audit_log_columns.exs`
- `apps/core/priv/repo/migrations/<ts>_audit_log_append_only_trigger.exs`
- `apps/core/priv/repo/migrations/<ts>_create_user_mfa.exs`
- `docs/runbooks/prod-data-access.md`
- Test files for each of the above

**Modified** (~12 files):
- `proto/stacks/internal/v1/audit.proto`, `proto/persisted.exs`
- `apps/core/mix.exs` (`:nimble_totp`)
- `apps/core/lib/stacks/audit.ex`
- `apps/core/lib/stacks/release.ex`
- `apps/core/lib/stacks/gdpr/deletion.ex`
- `apps/core/lib/stacks_web/plugs/rate_limiter.ex`
- `apps/core/lib/core_web/router.ex`
- `.github/workflows/deploy-production.yml`
- `scripts/lint-elixir.sh`
- `docs/runbooks/secrets-rotation.md`
- `docs/technical-architecture.md`
- `apps/core/lib/stacks/gen/audit/entry.ex` (auto-regenerated via `mix proto.sync`)
- `dbt/models/staging/stg_audit_log.{sql,yml}` (auto-regenerated via `mix proto.sync`)

## Out of Scope (deferred to follow-on issues)

- **Phase B** (signed short-lived credentials, `stacks-break-glass` CLI, pgaudit + R2 streaming): separate issue post-Phase-A merge.
- **Phase C** (RLS, column encryption expansion, transaction-scoped GUC, anomaly detection, 2-of-N escrow): separate issue post-Phase-B.
- Existing user-facing GDPR endpoints (`/api/gdpr/{export,account,consent}`): unchanged. They serve users for their own data; Phase A's `gdpr_export`/`gdpr_erase` are operator-on-behalf-of-user paths.
