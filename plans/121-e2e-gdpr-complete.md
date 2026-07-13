# Issue #121 Complete — E2E/GDPR v1 test-hardening + telemetry (epic root)

**Status**: COMPLETE (all 7 phases reviewer-APPROVED; DoD met)
**Branch**: `feat/e2e-121` (integration branch for the epic — PR deferred until child issues land)
**Type**: epic root — v1 GDPR test-hardening + in-scope telemetry + a P0 erasure fix

## Outcome
Issue #121's own deliverable is done. The originally-chartered v2 GDPR surface was
de-scoped (Approach A) into ordered child issues **#183–#189**, which remain to be
built on this branch before the single epic PR is opened.

## Phases
| Ph | Deliverable | Reviewer | Cycles |
|----|-------------|----------|--------|
| 1 | Erasure invariants: audit rows (`user.deletion_requested`/`user.data_deleted`) + event_log assertions | elixir-reviewer | 1 |
| 2 | Job-config + destructive-op safety (DataExportJob, AccountDeletionJob max_attempts:1, ImageRetentionJob cron) | elixir-reviewer | 0 |
| 3 | Image-retention storage-call spy + storage-failure resilience | elixir-reviewer | 0 |
| 4 | GDPR telemetry: 8 `[:stacks,:gdpr,…]` signals + Prom_Ex registration + firing tests | elixir-reviewer | 1 |
| 5 | E2E: GDPR 401 auth-guards + consent success/error (live preview 21/21) | testing-coordinator | 0 |
| 6 | Test Audit regenerated GREEN (43✅/0⚠️/0❌/87 n/a); epic scope reframed | — (docs) | 0 |
| 7 | **PE-gate P0**: scrub user PII from event_log on erasure + UUID-only emitters | elixir-reviewer (security) | 0 |

## Gates
- **2F Principal Engineer gate**: YELLOW → **P0 resolved in Phase 7** (event_log PII
  erasure); P2 documented; P1/P3 residue routed to the epic backlog (#184/#185).
- `just verify`: PASSED (Elixir 2338/0 at Ph6; 2230/0 domain re-run at Ph7; dbt 207/207).
- Live E2E: 21/21 against the deployed preview (`SKIP_VISION=1`).

## Key decisions (human)
- **Approach A** — #121 becomes an epic; v2 surface de-scoped into ordered child issues, not built in-scope.
- **Telemetry instrumented in-scope** (Phase 4), not de-scoped to the SLO gate.
- **P0 remediation = Both** — scrub-on-erasure (legacy rows) + UUID-only emitters (going forward); home = #121 Phase 7.
- **Epic execution**: complete all child issues on `feat/e2e-121`, full orchestrator flow per item, parallel worktrees where safe, single PR only when the whole epic is done.

## Commits (this branch, #121 work)
29abae6 (Ph2) · c6ec5fb (Ph3) · 9328a06 (Ph4) · bfe8eb7 (Ph5) · 6afa27c (Ph6 audit) ·
be4bb94 (Ph7 P0 fix) · a32947e (Ph7 sidecar: ISBNResolver flake fix)

## Remaining before the epic PR
Child issues **#183 (root) → {#184,#185,#186} → {#187,#188,#189}**, plus any issues
discovered mid-flight (e.g. the PE's cross-aggregate event_log residue → folds into #185).
Each runs the full orchestrator flow; all merge onto `feat/e2e-121`; then one PR.
