# Phase 5 Complete: Adopt actionlint in CI

**Issue**: #137
**Phase**: 5 of 7
**Agent**: platform-agent
**Reviewer**: platform-reviewer
**Verdict**: APPROVED
**Completed**: 2026-05-01
**Commit**: `9653376`

## Deliverables

- `.github/workflows/ci.yml` — new `lint-actions` job (~28 lines) gated on a new `workflows` filter (`.github/workflows/**` + `.github/actions/**`). Pinned to actionlint `v1.7.4`. 4 inline shellcheck fixes (3 rewrites + 1 justified `# shellcheck disable=SC2086` where word-splitting is intentional).
- `test/platform/rollback_action_composite_test.sh` — Case 8 fix: lint `deploy-production.yml` instead of `action.yml` standalone (actionlint v1.7.x can't lint composite action files in isolation; transitive validation via consuming workflow is the documented path).

## Behaviour locked

- **Install path:** upstream `download-actionlint.bash` script from rhysd/actionlint v1.7.4 tag → `$HOME/.local/bin/actionlint`. SHA256 verified against release manifest.
- **Lint scope:** all `.github/workflows/*.yml` + composite actions under `.github/actions/**/action.yml` (validated via `uses:` references in workflows).
- **CI gating:** `lint-actions` job runs only when `workflows` paths-filter matches. Bare `run: actionlint` — non-zero exit fails the job.
- **Backfill state:** 4 findings found, all style warnings, all in `ci.yml`. All fixed inline. Zero suppressions on the new `rollback-production` composite action.

## Gate Results

- 2A-iv Reception Gate: PASS (DoD evidence + reviewer's independent re-run)
- 2B-i Regression Gate: PASS — actionlint exit 0 across 5 workflows + composite action; 4 bash test suites green (80 + 81 + 44 + 45 = 250 assertions)
- 2B-ii Spec Coverage Gate: PASS — all section-7 Technical Requirements satisfied
- 2B-iia Fresh DB Gate: SKIPPED — CI-only change, no migrations
- 2B-iii Deploy Preview + E2E: SKIPPED — CI lint adoption is meta-CI; no deployed-env paths

## Reviewer Notes (carry-forward)

- **PyYAML in `flake.nix`** — Phase 3 carry-forward, still open. Phase 5 was the natural place but the operator scoped it out. File a follow-up if `.venv-tools/bin/python3` fallback becomes a friction point.
- **actionlint version bump cadence** — pinning to `v1.7.4` traded auto-bug-fixes for reproducibility. Bumping is a one-line edit; the comment at `ci.yml:367-370` calls this out so future maintainers know to pair the bump with a fresh local re-run in case the new version surfaces previously-missed findings.

## Forward Compatibility

- Phase 6 (runbooks): no workflow changes — actionlint scope unaffected.
- Phase 7 (live validation): the temporary `pull_request:` trigger removal in `deploy-production.yml` will be re-linted by the new job before merge.
