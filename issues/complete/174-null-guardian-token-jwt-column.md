# Issue #174: Stop persisting raw JWTs in op.guardian_tokens

## Summary
Eliminate the plaintext `jwt` column attack surface introduced with `guardian_db` (Issue #124 A2). The column stores the full signed bearer token but is **never read** by the verify/revoke/purge path (verification is by `jti` primary key + `aud`; purge is by `exp`). A SELECT-capable compromise (SQLi, backup/replica leak) of `op.guardian_tokens` currently yields directly replayable sessions. Store nothing (or a non-replayable value) in that column.

## User Stories
None directly — security hardening of the auth token store.

## Goal
After this issue, a full dump of `op.guardian_tokens` contains no usable bearer token — only the non-secret bookkeeping columns (`jti`, `aud`, `sub`, `typ`, `exp`, timestamps) that verification and revocation actually use. Logout revocation, per-request verification, and expired-token sweeping all continue to work unchanged.

## Scope Check
- One table + the Guardian.DB integration; < 300 LOC. Single concern. No split.

## Wiring
- [x] Implementation only (no user-facing change). Wired by #124's A2 (which this hardens).

## Technical Requirements
1. Prevent the raw JWT from being persisted to `op.guardian_tokens.jwt`. Options (choose per standards during implementation):
   - **Custom Guardian.DB adapter / `Token` schema override** that writes `NULL` (or omits) the `jwt` field on `after_encode_and_sign`. Preferred if guardian_db's config allows a custom `schema_name`/adapter cleanly.
   - If the column is `NOT NULL` or required by guardian_db's changeset, make it nullable via migration and override the changeset, or store a SHA-256 hash of the token (never the token) — noting the column is not queried by value, so `NULL` is simplest.
2. Migration to alter the existing `op.guardian_tokens.jwt` column (nullable / drop / rename) consistent with the chosen approach; backfill/`NULL` existing rows.
3. Verify the four Guardian.DB hooks (`after_encode_and_sign`, `on_verify`, `on_revoke`, `on_refresh`) still function: login stores a row, verify passes, logout revokes (row deleted → next request 401), sweep purges expired.
4. Confirm no code path reads `.jwt` (it doesn't today — guardian_db verifies by `jti`+`aud`).

## Reviewer Context
- Implemented on `feat/124-e2e-auth` after #124's other phases, before the PR opens.
- `guardian_db` owns the `Guardian.DB.Token` schema — overriding it may require a custom adapter module; weigh maintenance cost against a fork.
- The compensating control today is DB role isolation (only `stacks_app` is granted DML on `op.guardian_tokens`; `stacks_dbt` is not) plus the 8-hour access-token TTL added in #124. This issue removes the surface rather than relying solely on those.

## Test Audit

_Baseline generated 2026-07-08; regenerated GREEN 2026-07-10 after implementation. Approach: a `BEFORE INSERT OR UPDATE` trigger forces `jwt = NULL` at the data layer (enforced on every write path — login, the future refresh #173, anything), + a one-time scrub of existing rows._

| Layer | Happy | Verdict | Sad **(SECURITY)** | Verdict |
|-------|-------|---------|--------------------|---------|
| 1 API | n/a — no endpoint change | n/a | n/a | n/a |
| 2 Auth guards **(SECURITY)** | verify/revoke still work with jwt NULL | ✅ regression guards + guardian_test/sweep (10/0) | dumped `guardian_tokens` yields no replayable token | ✅ jwt NULL on INSERT+UPDATE (mutation-verified: drop trigger → raw token persists) |
| 3 DB / migration **(SECURITY)** | trigger nulls jwt; existing rows scrubbed; applies clean from scratch | ✅ fresh-DB gate (2269 tests) + reversible | column holds no raw bearer token — enforced by trigger, verified on live Neon | ✅ `:deployed_only` test: `jwt IS NULL` after live login |
| 5 Oban (sweeper) | expired-token purge still works (by `exp`) | ✅ guardian_token_sweep_job_test (unregressed) | n/a | n/a |
| 4,6–13 | n/a — no external/cache/dbt/cost/UI/event surface | n/a | n/a | n/a |

### Punch list (resolved)
| # | What's needed | Where | Status |
|---|---------------|-------|--------|
| 1 | Never persist a raw jwt (NULL) | `20260710000000_null_guardian_token_jwt.exs` — `BEFORE INSERT OR UPDATE` trigger forcing `NEW.jwt := NULL` | ✅ |
| 2 | Migration nulling jwt + scrub existing rows | same migration (`UPDATE … SET jwt = NULL WHERE jwt IS NOT NULL`) | ✅ |
| 3 | Test: after login `jwt IS NULL` (INSERT + UPDATE) | `guardian_db_jwt_test.exs` + live `guardian_jwt_deployed_test.exs` | ✅ |
| 4 | verify/revoke/sweep unregressed | `guardian_db_jwt_test.exs` guards + `guardian_test.exs` + `guardian_token_sweep_job_test.exs` | ✅ |

### Verdict
**GREEN.** A DB trigger forces `op.guardian_tokens.jwt = NULL` on every INSERT/UPDATE (mutation-verified load-bearing) — a dump contains no replayable bearer token. Existing rows scrubbed. All four Guardian.DB hooks (verify/revoke/refresh/sweep) unregressed. Proven end-to-end: fresh-DB gate (2269 tests), and a `:deployed_only` test confirming `jwt IS NULL` on a real Neon preview after a live login; E2E 195/0. database-reviewer APPROVED; PE GREEN. (Non-scope P3 notes: an optional scrub-specific test; the decoded `claims` column — not a replay vector.)

## Definition of Done
- [x] `op.guardian_tokens.jwt` no longer stores a usable bearer token (NULL, trigger-enforced)
- [x] Migration alters the column behaviour and scrubs existing rows
- [x] Login/verify/logout-revocation/expired-sweep all still pass (no #124 A2 regression)
- [x] Test asserts the persisted row has no replayable token (INSERT + UPDATE + live Neon)
- [x] Tests pass with `TEST_TARGET=local`; `just verify` passes
- [x] **Test audit (embedded above) is GREEN** — every applicable cell `✅` or `n/a`; 0 `❌`, 0 `⚠️`. Regenerate as the final step.

## Dependencies
- #124 A2 (guardian_db integration) — this hardens it. Same branch, after #124's phases, before the PR.

## Agent Assignment
security-agent + database-agent.

## Progress Notes
- 2026-07-08: Raised from #124 Phase 1 security review (P3, accepted-with-mitigation). #124 adds an 8h TTL + role isolation as interim bounds; this removes the surface. Do before opening the #124 PR.
- 2026-07-10: Implemented via orchestrator (database-agent). Chose a `BEFORE INSERT OR UPDATE` DB trigger forcing `NEW.jwt := NULL` (data-layer, covers login + future refresh + any path) + a one-time scrub — over an app-side override (weaker, path-dependent). No app-code change; `guardian.ex` untouched. TDD (RED→GREEN); testing-coordinator PASS (direct-SQL mutant confirmed the trigger is load-bearing). Gates: `just verify` exit 0; fresh-DB gate (migrate-from-scratch + 2269 tests + dbt); full 2B-iii deploy — migration applied on Neon, `:deployed_only` test confirmed `jwt IS NULL` live, E2E 195/0. database-reviewer APPROVED; PE GREEN (no P0/P1). Built on branch `174-…` off `feat/124-e2e-auth`. Confirmed the trigger already covers #173's future refresh path (no extra work there). P3 follow-ups (not filed): optional scrub-specific test; the decoded `claims` column (not a replay vector).
