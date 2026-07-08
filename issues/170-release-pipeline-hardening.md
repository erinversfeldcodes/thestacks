# Issue #170: Release-pipeline hardening — post-merge failures and preview-environment races

## Summary
The first post-merge run of the release pipelines (PR #204 → main, 2026-07-08) surfaced four release-process defects: two workflow failures on main (reseed-staging, OSSF Scorecard) and two preview-environment race conditions observed during the PR's deploy-preview cycles. Two are already fixed in-tree and need only verification; two need implementation.

## User Stories
N/A (platform / release engineering).

## Goal
Every workflow triggered by a push to main completes green, and local `just ci` and GitHub Actions can run their preview deploys concurrently without corrupting each other's environment.

## Scope Check
- Touches 0 controllers, 0 endpoints, ~60 LOC across workflows and shell scripts. No split needed.
- Four related concerns, but all are "the release process is trustworthy" — kept together deliberately; split 166a/166b if implementation drags.

## Wiring
- [x] This issue is implementation only. No router or UI changes.

## Technical Requirements

### A. reseed-staging: setup-beam gets empty inputs — FIXED, needs verification
**Symptom:** `##[error]Input required and not supplied: otp-version` on every main push.
**Cause:** `.github/workflows/reseed-staging.yml` extracted versions with `grep '^otp=' .versions`, but `.versions` uses uppercase shell-var format (`OTP_VERSION=28`). The greps matched nothing, so `erlef/setup-beam` received empty inputs. Latent — predates PR #204.
**Fix (in working tree):** the version step now does `source .versions` and emits `${OTP_VERSION}` / `${ELIXIR_VERSION}`, matching how `scripts/ci.sh` consumes the same file.
**Test:** commit, then `gh workflow run reseed-staging.yml` (or push to main) and confirm the run completes: setup-beam resolves OTP 28 / Elixir 1.18, seeds load, exit green. Regression guard: `actionlint` passes (already verified pre-commit).

### B. OSSF Scorecard: publish rejected due to workflow-global write permissions — FIXED, needs verification
**Symptom:** `workflow verification failed: global perm is set to write: permission for security-events is set to write` (HTTP 400 from the scorecard webapp, retried then fatal).
**Cause:** the PR #204 security-hardening pass set `security-events: write` and `id-token: write` at the **workflow** level in `.github/workflows/scorecard.yml`. scorecard-action's publish verification requires global read-only with writes scoped to the job (documented workflow restriction).
**Fix (in working tree):** `permissions: read-all` at workflow level; `security-events: write`, `id-token: write`, `contents: read`, `actions: read` moved into the `scorecard` job.
**Test:** commit, trigger the workflow (push to main or wait for the Monday cron), confirm publish succeeds and the SARIF upload lands. Regression guard: `actionlint` passes.

### C. Preview-environment collision between local `just ci` and CI's deploy-preview — NOT FIXED
**Symptom:** CI's deploy-preview job failed its IDOR step with "could not authenticate both seed users"; core logs showed `Postgrex ... The requested endpoint could not be found` at the same timestamp.
**Cause:** both local `just ci` and the GitHub runner derive the SAME preview names from the branch (`stacks-core-pr-<branch>` Fly app, `preview/<branch>` Neon branch). The local run finished first and its cleanup deleted the shared Neon branch while CI's job was mid-flight — its logins then 5xx'd against a database that no longer existed.
**Fix:** make CI's preview names unique — suffix with the workflow run id (e.g. `stacks-core-pr-<branch>-ci<run_id>` truncated to Fly's app-name limit, `preview/<branch>-ci<run_id>`). Thread through: ci.yml deploy-preview job env → `scripts/deploy-stack.sh` (it already accepts `--branch`; add an optional suffix or honour a `PREVIEW_SUFFIX` env var) → the corresponding cleanup path. Local runs keep the bare names. Mind Fly's 30-char app-name cap — the branch component may need tighter truncation when the suffix is present.
**Test:** (1) unit-ish: run `deploy-stack.sh --branch x` with and without `PREVIEW_SUFFIX` set and assert the emitted app/branch names differ and respect length caps (the script prints them — assert with grep in a small bats/bash test or a dry-run mode). (2) integration: trigger CI deploy-preview while a local `just ci` runs against the same branch; both must complete without cross-teardown. (3) confirm cleanup deletes only its own suffixed resources (list Fly apps + Neon branches after both complete; no orphans, no cross-deletion).

### D. Teardown ordering: Neon branch deleted while Fly machines still serve traffic — NOT FIXED
**Symptom:** post-run `Postgrex ... endpoint could not be found` errors in core logs after E2E completes (observed 2026-07-07 19:12).
**Cause:** cleanup deletes the Neon preview branch first; the Fly machines stay up (until autostop) with pooled connections now pointing at a dead endpoint. Harmless today but noisy, masks real DB errors in logs, and C's fix makes correct ordering matter more (suffixed stacks are torn down more often).
**Fix:** in the cleanup path (`scripts/cleanup-preview.sh` / the ci.sh deploy-phase cleanup), stop/scale-to-zero the Fly app(s) BEFORE deleting the Neon branch: `fly scale count 0 --app <app> --yes` (or `fly apps destroy` where the app is per-run disposable under C).
**Test:** run the cleanup against a live preview and tail core logs during teardown — zero Postgrex endpoint errors after the stop completes; Neon branch gone; Fly app stopped/destroyed.

## Reviewer Context
- `.versions` is the canonical version-pin file, consumed by `source` (uppercase shell vars) — never grep lowercase keys.
- All workflow `uses:` references are SHA-pinned with trailing version comments (PR #204 hardening); keep that convention in any workflow edits here.
- `scripts/deploy-stack.sh` derives names via `tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30`; the suffix work in C must respect the same sanitisation and Fly's app-name length limit.
- The IDOR/auth failures in C's symptom were NOT an auth regression — do not "fix" auth for this.

## Definition of Done
- [ ] A: reseed-staging workflow green on a main push (or manual dispatch) with correct OTP/Elixir resolution.
- [ ] B: Scorecard workflow green including publish; SARIF visible in the Security tab.
- [ ] C: CI deploy-preview uses run-id-suffixed Fly app + Neon branch names; concurrent local + CI runs verified non-interfering; cleanup removes only its own resources.
- [ ] D: cleanup stops Fly app(s) before Neon branch deletion; teardown produces no Postgrex endpoint errors.
- [ ] `actionlint` and `shellcheck` pass on all touched files.
- [ ] Tests written and passing (C's name-derivation assertions; D's teardown log check documented as a manual verification step in the script header if not automatable).
- [ ] Standards compliance verified (`just verify` passes).

## Dependencies
None. A and B fixes already sit uncommitted in the working tree from the post-merge triage session.

## Agent Assignment
platform-agent (workflows + deploy/cleanup scripts). No app-code changes expected.

## Progress Notes
- 2026-07-08: A and B root-caused and patched in-tree during post-merge pipeline watch (actionlint-verified). C and D root-caused with production log evidence; unimplemented.
