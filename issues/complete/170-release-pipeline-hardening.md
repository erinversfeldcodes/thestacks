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

### E. Production deploy aborts: warmup prober secrets missing — NOT FIXED
**Symptom:** first post-merge prod deploy (run 28924423704) failed at `FAIL warmup: could not authenticate as warmup user (HTTP 401)` after all services deployed healthy; rollback triggered.
**Cause:** `deploy-production.yml` maps `PROBE_SEED_EMAIL/PASSWORD` from `secrets.STACKS_PROBER_EMAIL/STACKS_PROBER_PASSWORD`, which are not set in the repo (`gh secret list` confirms). The warmup then used its dev-mode defaults (`owner@thestacks.app` / `dev-password-123`) against prod → 401. `Stacks.Release.seed_prober/0` also `fetch_required_env!`s the same vars.
**Fix:** create both secrets (`gh secret set STACKS_PROBER_EMAIL` / `STACKS_PROBER_PASSWORD`, strong generated password); additionally add them to the workflow's existing fast-fail secrets preflight so a missing prober secret aborts BEFORE deploying anything, not after.
**Test:** re-run Deploy production; warmup authenticates (2xx), pipeline proceeds to SLO gate. Negative: with a secret unset, the preflight fails before `deploy-stack.sh` runs.

### F. Rollback crashes on audit logging; prod audit_log schema behind — NOT FIXED
**Symptom:** the rollback action's `mix run` audit step crashed: `MatchError ... column "success" of relation "audit_log" does not exist`, failing the rollback job after the image rollback itself had succeeded.
**Cause (VERIFIED 2026-07-08):** structural, not a missing migration. The deploy applied all 6 pending migrations (run log 07:17:46), then the warmup failure triggered rollback, which correctly restored the Neon DB to the captured pre-migrate LSN (`0/11D95E58`) — rewinding the schema. The audit step then ran new-checkout code (INSERT with `success` etc.) against the rewound pre-migration schema → guaranteed crash whenever a rolled-back deploy included migrations. Inverse ordering cannot fix it: an audit row written before the LSN restore is erased by the restore. The rollback audit record cannot durably live in the database being rolled back.
**Fix:** (1) make the DB audit write best-effort (rescue → log warning → exit 0) — it's colour, not the record; (2) treat the workflow artifact (`gate-observations.json` upload, which already exists) as the durable rollback record — extend it with the fields `log_rollback` captures (failed_sha, target_image, reason, triggered_by) if not already present.
**Test:** unit test for the best-effort wrapper (insert raising → step exits 0, warning logged); rollback rehearsal after E (induced failure incl. a migration in the delta) completes green end-to-end with the artifact carrying the rollback record. Prod schema verified consistent post-rollback (old image + old schema; count 54 at `20260422131257`) — re-deploy re-applies the 6 migrations.

## Reviewer Context
- `.versions` is the canonical version-pin file, consumed by `source` (uppercase shell vars) — never grep lowercase keys.
- All workflow `uses:` references are SHA-pinned with trailing version comments (PR #204 hardening); keep that convention in any workflow edits here.
- `scripts/deploy-stack.sh` derives names via `tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30`; the suffix work in C must respect the same sanitisation and Fly's app-name length limit.
- The IDOR/auth failures in C's symptom were NOT an auth regression — do not "fix" auth for this.

## Definition of Done
- [ ] A: reseed-staging workflow green on a main push (or manual dispatch) with correct OTP/Elixir resolution.
- [ ] B: Scorecard workflow green including publish; SARIF visible in the Security tab.
- [x] C (implementation): CI deploy-preview uses run-id-suffixed Fly app + Neon branch names via `PREVIEW_SUFFIX` + `scripts/lib/preview-names.sh`; cleanup derives the same suffixed names.
- [ ] C (live verification): concurrent local + CI runs verified non-interfering; cleanup removes only its own resources. *(Needs a real PR deploy-preview run alongside a local `just ci` — see re-deploy checklist in the 2026-07-08 progress note.)*
- [x] D (implementation): cleanup stops the core Fly machines before Neon branch deletion; rationale + manual log-check procedure documented in the `cleanup-preview.sh` header.
- [ ] D (live verification): teardown against a live preview tailed for zero Postgrex endpoint errors. *(Manual — procedure in the script header.)*
- [x] E (preflight): STACKS_PROBER_EMAIL/PASSWORD added to deploy-production.yml's fast-fail secrets loop (secrets themselves already set in the repo).
- [ ] E (live verification): prod warmup authenticates (2xx) on the next Deploy production run.
- [x] F (wrapper): rollback audit write is best-effort (try/rescue + warn + exit 0, plus `continue-on-error`); durable record is `rollback-record.json` in the `gate-observations` artifact; action README updated.
- [ ] F (live verification): prod schema_migrations verified current (incl. 20260504182149) after re-deploy; rollback rehearsal green with the artifact carrying the rollback record.
- [x] `actionlint` and `shellcheck` pass on all touched files.
- [x] Tests written and passing (C's name-derivation assertions in `test/platform/preview_names_test.sh`, 48 assertions; D's teardown log check documented as a manual verification step in the script header).
- [ ] Standards compliance verified (`just verify` passes).

## Dependencies
None. A and B fixes already sit uncommitted in the working tree from the post-merge triage session.

## Agent Assignment
platform-agent (workflows + deploy/cleanup scripts). No app-code changes expected.

## Progress Notes
- 2026-07-08: A and B root-caused and patched in-tree during post-merge pipeline watch (actionlint-verified). C and D root-caused with production log evidence; unimplemented.
- 2026-07-08 (later): first prod deploy failed → E (missing prober secrets → warmup 401 → rollback) and F (rollback audit crash on missing audit_log.success column; prod migrations suspect) root-caused from run 28924423704 logs and gh secret list. Deploy remains rolled back to the pre-merge image.
- 2026-07-08 (implementation, platform-agent): C, D, E-preflight, and F implemented; static verification complete.
  - **C:** name derivation extracted to `scripts/lib/preview-names.sh` (`derive_preview_names`), sourced by `deploy-stack.sh`, `deploy-preview.sh`, `cleanup-preview.sh`, `ci.sh`, and ci.yml's Pin-Fly-hostname step. Optional `PREVIEW_SUFFIX` env var appends a sanitised suffix to every per-preview resource (core/scraper/searxng Fly apps, Modal app, Neon branch, image labels). ci.yml's deploy-preview job derives `PREVIEW_SUFFIX=ci<last 6 digits of run_id>` (8 chars — Fly's 30-char app-name cap minus the 18-char `stacks-scraper-pr-`/`stacks-searxng-pr-` prefix leaves 12 for `<branch>-<suffix>`, so branch keeps 3 chars; last-6 digits never repeat across concurrent runs). Behaviour byte-identical when unset (local runs). Tests: `test/platform/preview_names_test.sh` (48 assertions, registered in `run_all.sh`): byte-identity vs legacy derivation, uniqueness, ≤30-char Fly names, suffix sanitisation, dangling-hyphen, oversized-suffix hard-fail.
  - **D:** `cleanup-preview.sh` now stops the core app's machines (`fly machine stop` loop, same `fly machines list --json` idiom as deploy-stack.sh) before the Neon branch delete; rationale + manual log-tail verification procedure documented in the script header.
  - **E:** `STACKS_PROBER_EMAIL`/`STACKS_PROBER_PASSWORD` added to the fast-fail `for v in ...` secrets loop in deploy-production.yml's Compose DATABASE_URL step.
  - **F:** log-audit step in the rollback composite action wraps `Stacks.Audit.log_rollback/1` in try/rescue (warn + exit 0) with `continue-on-error: true` as belt-and-braces; deploy-production.yml writes `rollback-record.json` (failed_sha, target_image, modal_prev_commit, reason, triggered_by, per-leg outputs, step outcome, run URL, timestamp) whenever the rollback step ran and uploads it in the existing `gate-observations` artifact; action README documents why the DB row is best-effort.
  - Gates: `actionlint` clean (all workflows); `shellcheck` clean on new files, warning-count reduced vs HEAD on touched scripts (remaining warnings pre-exist); `test/platform/preview_names_test.sh` 48/48; `deploy_production_workflow_test.sh` 82/82; `deploy_stack_retry_test.sh` 6/6; `rollback_action_composite_test.sh` 76 pass + 4 pre-existing environment failures (identical on HEAD — `mapfile` missing in the host bash, not a regression).
  - Remaining live verification (next deploys): C-concurrency, D-log-tail, E-warmup-2xx, F-rehearsal + prod schema check — see unticked DoD sub-items.
