# Phase 6 Complete: Runbooks + follow-ups

**Issue**: #137
**Phase**: 6 of 7
**Agent**: platform-agent (with revision cycle 1 fixes from orchestrator)
**Reviewer**: platform-reviewer
**Verdict**: APPROVED (after 1 revision cycle)
**Completed**: 2026-05-02
**Commit**: `3d1b607` (runbooks only — follow-up issue files left untracked per operator)

## Deliverables

- `docs/runbooks/manual-rollback.md` (305 lines, committed) — opens with the corrected behavioural contract (image-only revert; Neon DB is NOT rolled back on this path; image N-1 reads schema N safely under expand-contract). Covers prereqs, invocation, expected step sequence, three composite-action outputs, post-rollback verification (with accurate audit SQL + Cloak-encryption caveat), and four failure modes.
- `docs/runbooks/migration-recovery.md` (267 lines, committed) — forward-fix vs trust-auto-rollback vs `mix ecto.rollback`-local-dev-only decision tree. Documents the canonical migration-failure shape `(core=false, db=true, modal=true)`. Cross-references migration-safety lint and pre-rollback-* branch promotion.
- `issues/162-cleanup-pre-rollback-neon-branches.md` (untracked) — scheduled cleanup of `pre-rollback-*` Neon branches >30d old.
- `issues/163-bootstrap-prod-environment-runbook.md` (untracked) — fresh prod-stack setup runbook.
- `issues/164-pin-pyyaml-in-flake.md` (untracked) — pin `python312Packages.pyyaml` in `flake.nix` dev shell.

## Behaviour locked

- `manual-rollback.md` Behavioural contract — accurate to implementation: capture-lsn skipped on manual path → empty `pre-migrate-lsn` → script-level skip → no DB rollback → no row-level data loss. Image N-1 + schema N safe under expand-contract.
- `migration-recovery.md` migration-failure shape — accurate to implementation: core skipped (image-equality short-circuit), DB reset (LSN reset earns its keep), Modal redeployed (idempotent re-deploy of identical artifact).
- Audit-row verification SQL uses `occurred_at` (not `inserted_at`); `resource_id` carries `failed_sha`; `metadata` is Cloak-encrypted bytea — operators read `triggered_by` from the workflow's `log-audit` step output, not raw SQL.

## Gate Results

- 2A-iv Reception Gate: PASS (independent verification of all 4 reviewer findings)
- 2B-i Regression Gate: PASS — 4 bash test suites green (250/0); actionlint clean
- 2B-ii Spec Coverage Gate: PASS — all section-7 + Phase 6 plan items satisfied
- 2B-iia Fresh DB Gate: SKIPPED — documentation-only phase
- 2B-iii Deploy Preview + E2E: SKIPPED — documentation-only phase

## Revision Cycle 1 (4 fixes)

- **P0-1:** Audit SQL column name + Cloak-encryption caveat in `manual-rollback.md`.
- **P0-2:** Modal-leg shape in `migration-recovery.md` migration-failure path (Modal redeploys, doesn't skip).
- **P1:** Bootstrap cross-references replaced with issue #163 pointer + inlined one-liner (no broken links).
- **P2:** `db-rolled-back=error` overclaim narrowed to two legitimate upstream-failure cases.

All 4 verified PASS in re-review.

## Forward Compatibility

Phase 7 (live validation) will exercise the manual-rollback path documented in `manual-rollback.md`. The runbook's invocation command (`gh workflow run deploy-production.yml -f manual_rollback=true`), expected step sequence table, and post-rollback verification checklist are ready for Phase 7's operator-driven observations.
