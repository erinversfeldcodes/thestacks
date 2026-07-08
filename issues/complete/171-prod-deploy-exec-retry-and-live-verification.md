# Issue #171: Prod deploy exec retry + release-pipeline live verification

## Summary
The second production deploy attempt (run 28928687981) cleared every #170 fix that could be exercised — preflight secrets, migrations, owner seed — then died on a *new* defect: a transient Fly machine-exec `EOF` aborted the prober seed and rolled back an otherwise-healthy release. This issue covers that defect (G, continuing #170's lettering) plus the live-verification items that were still open when #170 was closed on merge.

## User Stories
None directly — release-engineering hardening in service of all deployed features.

## Goal
A Deploy production run completes end-to-end (preflight → migrations → seeds → warmup → SLO gate → Tag main un-skips), and every #170 fix that could only be verified live has been observed working in a real run.

## Scope Check
- One script (`scripts/deploy-stack.sh`) and zero application code — no split needed.
- Remaining items are verification-only (workflow runs + log inspection), not implementation.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ *(N/A — ops/release tooling, no app wiring).*

## Technical Requirements

### G. Prod machine execs are one-shot; transient Fly exec EOF aborts the deploy — FIXED in tree, needs commit + verification
**Symptom:** run 28928687981 passed preflight, applied all 6 migrations, seeded the prod owner, then died at the prober seed with `failed_precondition: exec request failed: EOF` — triggering a full (correct) rollback of an otherwise-healthy release. The Neon pre-migrate LSN restore worked as designed, so prod is again consistent at the pre-merge image.
**Cause:** the three prod `fly machine exec` calls in `scripts/deploy-stack.sh --production` (in-container migrate, `seed_prod`, `seed_prober`) were one-shot `|| exit 1`, unlike every deploy command in the same script, which goes through the `deploy_with_retry` helper. Machine execs issued right after a rolling deploy are the flakiest calls in the pipeline — the machine is settling and the exec channel can drop.
**Fix (in working tree, uncommitted):** all three execs wrapped in the existing `deploy_with_retry` helper (one retry after a 5s pause — proportionate to the observed settle-window flake), with a comment citing the failing run. `bash -n` passes; shellcheck findings unchanged (6 pre-existing before and after).
**Test:** live — the next Deploy production run completes its seed phase. If Fly flakes again, the retry path is visible in the job log as a "retrying" line from `deploy_with_retry` instead of an abort.

### Live verifications carried over from #170 (closed on merge with these DoD boxes open)
Already verified live during deploy attempt 2 — record here, no action needed:
- **#170 B (Scorecard):** run 28928688084 on main succeeded.
- **#170 E (prober-secret preflight):** run 28928687981 preflight passed with `STACKS_PROBER_EMAIL`/`STACKS_PROBER_PASSWORD` present; warmup was never reached, so full warmup-auth verification folds into this issue's deploy run.

Still outstanding:
- **#170 A (reseed-staging):** the fix (`source .versions`) has not run live. **Test:** `gh workflow run reseed-staging.yml` and confirm success; check whether the workflow's path filters explain why it did not auto-trigger on merge, and widen them if reseeding should follow every main merge.
- **#170 C (preview-name isolation):** PREVIEW_SUFFIX derivation is unit-tested (48 assertions) but the collision scenario has not been reproduced live. **Test:** run a local `just ci` deploy-preview concurrently with a PR's CI deploy-preview; confirm distinct app/branch names and that each cleanup removes only its own resources.
- **#170 D (teardown ordering):** **Test:** inspect the next preview teardown log — Fly apps must stop before the Neon branch delete, with no post-delete connection errors.
- **#170 F (rollback audit + artifact):** best-effort audit and `rollback-record.json` artifact are implemented but a rollback with migrations in the delta has not exercised them since. **Test:** rehearsal — force a warmup failure on a preview (or accept the next real rollback as evidence) and confirm the workflow ends green with the artifact uploaded and no audit crash.

## Reviewer Context
- `deploy_with_retry` already existed in `scripts/deploy-stack.sh` for deploy commands; G reuses it rather than adding a new mechanism.
- Rollback restores the Neon DB to the captured pre-migrate LSN, so a rolled-back deploy leaves prod at the pre-merge image with 54 migrations — re-deploying re-applies the 6 pending migrations. This is expected, not drift.
- Issue numbering: defect lettering continues #170 (A–F) so run logs and progress notes cross-reference cleanly.
- House rule: agents never `git commit` — the retry patch is committed by the user.

## Definition of Done
- [ ] G: `deploy-stack.sh` retry wrappers committed to main; shellcheck findings unchanged.
- [ ] G: a Deploy production run completes the seed phase (with or without a visible retry).
- [ ] Deploy production green end-to-end: preflight → migrations → seeds → warmup auth 2xx → SLO gate → Tag main runs (not skipped).
- [ ] #170 A: reseed-staging succeeds on manual dispatch; auto-trigger path filters reviewed.
- [ ] #170 C: concurrent local + CI preview runs verified non-interfering.
- [ ] #170 D: teardown log shows app-stop before Neon branch delete.
- [ ] #170 F: rollback rehearsal (or next real rollback) ends green with `rollback-record.json` artifact and no audit crash.
- [ ] Tests written and passing *(N/A beyond existing `test/platform/preview_names_test.sh` — remaining items are live verifications)*
- [ ] Standards compliance verified (`just verify` passes)

## Dependencies
- Issue #170 (merged, PR #205) — all fixes this issue verifies live.
- GitHub environment secrets `STACKS_PROBER_EMAIL` / `STACKS_PROBER_PASSWORD` (created during #170 E).

## Agent Assignment
platform-agent.

## Progress Notes
- 2026-07-08: G root-caused from run 28928687981 and patched in the working tree (uncommitted). #170 B and E-preflight verified live in the same run. Prod remains safely rolled back to the pre-merge image; next deploy re-applies 6 migrations.
