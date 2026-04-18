# Phase 2 Complete: Expand–Contract CI Enforcement

**Issue**: #136
**Phase**: 2 of 3
**Status**: Complete, committed, CI green
**Completed**: 2026-04-18

## Scope delivered
- Destructive squawk rules enabled: `ban-drop-column`, `renaming-column`, `renaming-table`, `adding-required-field` (dropped `adding-field-with-default` — false positive on PG 11+).
- `scripts/lint-migrations.sh` — Python-backed Ecto DSL destructive-op detector with `@breaking_ok "<reason>"` annotation bypass. Handles `drop_column`, `drop_table`, `rename to:`, `modify ..., null: false` (including multi-line forms).
- `scripts/check-schema-diff.sh` — structure.sql differ detecting column DROP, RENAME, enum value drops, `ALTER TYPE ... DROP VALUE`, `DROP TYPE`. `DB_BREAKING_LABEL=true` env var bypasses.
- `migration-safety` job in `.github/workflows/ci.yml`: gated on `changes.outputs.migrations == 'true' && github.event_name == 'pull_request'`. Swaps the migrations dir between origin/main and HEAD state via `git checkout <ref> -- apps/core/priv/repo/migrations/`, runs `mix ecto.migrate` + `mix ecto.dump` against each, diffs them.
- `squawk-cli@2.47.0` pinned in both `ci.yml` and `setup.sh`.
- `docs/agents/standards/migrations.md` — codifies expand–contract rules, `@breaking_ok` trust model, deletion/squashing policy, and the "no app imports from migrations" anti-pattern. Registered in `CLAUDE.md` and `AGENTS.md`.
- Test harness: 39 assertions across 4 suites (`test/platform/*.sh`). Fixtures in `test/fixtures/migrations/` and `test/fixtures/schema/`. Real-baseline self-diff regression test against production-shape `structure.sql`.

## Commits on branch
| SHA | Title |
|-----|-------|
| `3ba1e03` | `feat: enable destructive squawk rules with test harness` |
| `fc5a184` | `feat: migration linter with @breaking_ok annotation` |
| `ad15a82` | `feat: schema diff with DB_BREAKING_LABEL bypass` |
| `7a1345d` | `feat: add migration-safety CI job` |
| `bd8c79d` | `chore: temporarily disable deploy-preview while iterating` |
| `fd4313d` | `fix: run mix deps.get before scripts/gen-ecto-proto.sh` |
| `35a05fc` | `refactor: dump structure by swapping migrations dir` |
| `a788a12` | `doc: add migration standards with anti-pattern rules` |
| `88b0fed` | `doc: clarify migration-safety gate detection posture` |

## Deferred to follow-up (tracked)
- **Two-step reference check** (plan step 4): mechanical verification that destructive migrations point to a prior merged commit that removed the code reference. `@breaking_ok` is currently a free-text speed-bump, not a mechanical safeguard. Documented in `scripts/lint-migrations.sh` and `docs/agents/standards/migrations.md`.
- **Migration that imports an app module** is not mechanically detectable by the schema-diff gate (may silently produce wrong diff). Caught only by reviewer audit per the migrations standards doc.

## Review history
- Cycle 0: NEEDS_REVISION with 4 P0 + 3 P1 + 3 P2 findings from platform-reviewer.
- Cycle 1: all 10 findings resolved. APPROVED.
- Delta review (after commits `fd4313d`, `35a05fc`, `a788a12`, `88b0fed`): APPROVED with one non-blocking nit (CI comment), since addressed in `88b0fed`.
- Pre-Phase-3 readiness review: READY_FOR_PHASE_3.

## Gate evidence
- 2B-i Regression: `bash test/platform/run_all.sh` — 39/39 PASS. `mix test` — 1875/0. `mix credo --strict` clean.
- 2B-ii Spec Coverage: 4/4 Phase 2 DoD items have implementation + test evidence.
- 2B-iia Fresh DB: SKIPPED — no migrations in diff.
- 2B-iii E2E: SKIPPED — CI-config only, no deployed-env code changes.
- CI on branch: green.

## Residual for merge to main (not Phase 2 scope — flagged for merge checklist)
- Uncomment `deploy-preview` job in `ci.yml` (currently lines 554–747).
- Restore full `needs:` list on `deploy-preview` per TODO comment at line ~433.
- Restore other pre-existing commented-out jobs (test-elixir, test-elm, test-rust, test-python, lint-proto, test-dbt, gitleaks, hadolint, semgrep, checkov, trivy, security-squawk, check-licenses, trufflehog, syft-grype, dockle) as their stability returns — not Phase 2's responsibility, pre-existing state.
