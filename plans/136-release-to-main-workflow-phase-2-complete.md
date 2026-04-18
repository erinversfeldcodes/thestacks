# Phase 2 Complete: Expand–Contract CI Enforcement

**Issue**: #136
**Phase**: 2 of 3
**Status**: Approved, awaiting commit
**Completed**: 2026-04-18

## Scope delivered
- Destructive squawk rules enabled: `ban-drop-column`, `renaming-column`, `renaming-table`, `adding-required-field` (dropped `adding-field-with-default` — false positive on PG 11+).
- `scripts/lint-migrations.sh` — Python-backed Ecto DSL destructive-op detector with `@breaking_ok "<reason>"` annotation bypass. Handles `drop_column`, `drop_table`, `rename to:`, `modify ..., null: false` (including multi-line forms).
- `scripts/check-schema-diff.sh` — structure.sql differ detecting column DROP, RENAME, enum value drops, `ALTER TYPE ... DROP VALUE`, `DROP TYPE`. `DB_BREAKING_LABEL=true` env var bypasses.
- `migration-safety` job in `.github/workflows/ci.yml`: gated on `changes.outputs.migrations == 'true' && github.event_name == 'pull_request'`. Runs proto gen + mix ecto.migrate + mix ecto.dump against both HEAD and origin/main worktrees, diffs them.
- `squawk-cli@2.47.0` pinned in both `ci.yml` and `setup.sh`.
- Test harness: 39 assertions across 4 suites (`test/platform/*.sh`). Fixtures in `test/fixtures/migrations/` and `test/fixtures/schema/`. Real-baseline self-diff regression test against production-shape `structure.sql`.

## Deferred to follow-up
- Two-step reference check (plan step 4): mechanical verification that destructive migrations point to a prior merged commit that removed the code reference. `@breaking_ok` is currently a free-text speed-bump, not a mechanical safeguard. Documented in `scripts/lint-migrations.sh` trust-model section.

## Revision cycles
- Cycle 0: NEEDS_REVISION with 4 P0 + 3 P1 + 3 P2 findings.
- Cycle 1: all 10 findings resolved. APPROVED.

## Gate evidence
- 2B-i Regression: `bash test/platform/run_all.sh` — 39/39 PASS.
- 2B-ii Spec Coverage: 4/4 Phase 2 DoD items have implementation + test evidence.
- 2B-iia Fresh DB: SKIPPED — no migrations in diff.
- 2B-iii E2E: SKIPPED — CI-config only, no deployed-env code changes.

## Files
Modified:
- `.github/workflows/ci.yml`
- `scripts/security-squawk.sh`
- `scripts/security-squawk-test-wrapper.sh`
- `setup.sh`

Created:
- `scripts/lint-migrations.sh`
- `scripts/check-schema-diff.sh`
- `test/platform/` (harness + 4 test suites)
- `test/fixtures/migrations/` (destructive + elixir fixtures)
- `test/fixtures/schema/` (before/after fixtures + real baseline + README)
