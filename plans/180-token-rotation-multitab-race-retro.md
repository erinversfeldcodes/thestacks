# Retrospective — Issue #180 (token-rotation multi-tab / in-flight race)

**Date**: 2026-07-12 · **Agents**: security+database (P1), elm (P2) · **Revision cycles**: 1 · **Outcome**: gates green (live grace + cross-tab E2E), ready to merge — batch #178–182 COMPLETE

## What worked well
- **Recognising that #179 changed the problem.** The issue offered frontend-only options, but #179's
  family-burn meant a stale-token 401 now nukes the whole family — so a re-check-before-logout alone
  couldn't help (the burn already happened). Grounding that led to the correct combined design:
  backend grace (prevents the burn) + cross-tab (idle tabs adopt the new token). Getting the design
  right up front avoided shipping a frontend-only non-fix.
- **The adversarial security review earned its keep on the softening.** Because the grace deliberately
  WEAKENS #179, the reviewer specifically checked it couldn't be widened or chain-extended — and
  proved the bound holds only because guardian_db deletes the rotated row (so a graced token can't
  re-stamp its own grace via /refresh). That's a subtle, load-bearing property worth having verified.
- **The elm review caught two real P1s that were the exact failures #180 exists to prevent** — a
  cross-tab adopt that left a parked logout (→ spurious multi-tab logout) and a page-origin reschedule
  storm. Both were live logic holes, not nits; the fixes (clear `pendingLogout` on adopt; a
  `fromRenewal` flag) were small and pure-testable.
- **Pure-helper seams made a Nav.Key-bound flow testable.** `adoptExternalAuth`/`resolveRecheck`/
  `parkPending` kept the deferred-logout decision out of the untestable Main loop; 631 elm tests.
- **The live gate proved the RIGHT thing.** The grace's job is burn-prevention (not making the old
  token succeed); the HTTP check asserted exactly that — within grace the current token survives a
  stale-token replay, past grace it burns. Plus the cross-tab E2E ran live.

## What caused friction
- **A lost untracked migration file caused a silent, confusing failure.** The Phase-1 migration file
  vanished mid-issue; the first symptom was `accounts_test` failing on a missing column, then the
  preview fail-closing every auth request. Diagnosing it meant tracing schema_migrations vs the file
  vs the columns across local + preview DBs. LESSON: an uncommitted migration is fragile; commit
  migrations promptly, and treat "column does not exist" in the family gate as a migration-state check.
- **The preview deploy silently skipped a pending migration** ("Migrations already up" with neither the
  record nor the columns present) — a deployment-integrity problem that turned into the exact
  fail-closed auth outage the #179 runbook was written for. Unblocking the gate required manually
  ALTERing the ephemeral preview DB. This deserves its own investigation (flagged).
- **The Neon preview-DB URL lives in the staging project with a non-obvious connection_uri endpoint**
  (query params, not a nested path) — a second session in a row lost to Neon-API archaeology.

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `docs/agents/orchestrator-agent.md` (Phase 2A) | When a phase adds a migration, COMMIT it (or stage it) immediately after the fresh-DB check — an untracked migration can vanish on a branch switch/clean and fails silently later. | #180's lost migration file. |
| `docs/agents/database-agent.md` / migrations.md | Add a diagnostic note: a fail-closed 401 storm or "column does not exist" in an auth/gate query almost always means a migration didn't apply — check `schema_migrations` vs the actual columns vs the file on BOTH local and the deployed DB. | The preview fail-closed outage. |
| New issue | Investigate why `Stacks.Release.migrate()` reported "already up" for a pending, unapplied migration on a fresh CoW preview — this can silently skip migrations on any deploy. | The deploy anomaly. |
| `.claude/skills/write-validation-test/SKILL.md` (deployed) | Record the preview-DB URL resolution: staging Neon project (`NEON_STAGING_PROJECT_ID`), branch id via `/branches`, connection via `GET /projects/{id}/connection_uri?branch_id=&database_name=&role_name=` (query params). | Two sessions of Neon-API archaeology. |

## Follow-ups
- **Deployment-integrity investigation** (the "already up" skip) — recommend filing; could affect any migration.
- The security P2: in the pre-existing revoke-failure degraded path, a graced token could re-enter
  /refresh and re-stamp its grace (bounded by guardian_db health; already-alerted state). Low urgency.

## Batch position
Follow-up #5 (LAST) of #178–182. **The batch is complete** (181 → 178 → 182 → 179 → 180, per-issue gates).
