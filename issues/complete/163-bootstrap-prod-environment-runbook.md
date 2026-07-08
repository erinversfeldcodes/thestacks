# Issue #163: `docs/runbooks/bootstrap-prod-environment.md` for fresh prod-stack setup

## Summary
A second prod environment (different region, different stack name,
different Fly app) has no prior `main-<sha>` git tags, so the
`record-prev-state` step in `deploy-production.yml` resolves
`MODAL_PREV_COMMIT` to empty. The first auto-rollback on that
environment would skip the Modal vision leg by design. This issue
captures the one-time bootstrap procedure as a runbook so future
operators can seed an initial tag before the first deploy without
having to reverse-engineer the workflow.

## User Stories
N/A (platform / operational).

## Goal
A future operator spinning up a second prod stack (e.g. a EU-region
mirror, a sacrificial pre-prod environment that exercises real
deploy-production.yml) has a clear procedure that doesn't require
reading the workflow file or `record-prev-state`'s shell script.

## Scope Check
- One new doc. Zero controllers, zero endpoints, zero new code.
- ~100 LOC of Markdown.
- Single concern: bootstrap procedure for a fresh prod stack. No
  bundled scope.

## Wiring
- [x] Implementation only (documentation). Wired by this issue.

## Technical Requirements

### New runbook: `docs/runbooks/bootstrap-prod-environment.md`

Sections (mirror existing runbook template — header block with
`Severity:`, `Owner:`, `Last reviewed:`):

1. **Header block.** Severity P2 (one-time bootstrap, planned), Owner
   Platform operator.
2. **When to use this runbook.** A new prod environment is being
   provisioned for the first time and there are no `main-<sha>` tags
   in the repo yet (or none for this environment's branch).
3. **Prerequisites.** Fly app exists (`fly apps create thestacks-core-eu`
   or similar); Neon project provisioned and `NEON_PROJECT_ID` /
   `NEON_API_KEY` staged as repo secrets; all Fly + Modal +
   Cloak + DB-component secrets staged. Modal app namespace (`MODAL_APP_NAME`
   default is `thestacks-vision`) reserved.
4. **The bootstrap one-liner.**
   ```bash
   git tag main-bootstrap "$(git rev-parse main^)"
   git push origin main-bootstrap
   ```
   Commentary: this seeds a single `main-*` tag pointing at HEAD~1, so
   `record-prev-state`'s `git tag --list 'main-*' --sort=-committerdate
   | head -2 | tail -1` returns a real SHA. The tag points at HEAD~1
   rather than HEAD because the first deploy is going to deploy HEAD;
   the bootstrap tag is the **prev** target, not the current one.
5. **Verification.** After pushing the tag, confirm
   `record-prev-state` resolves to a non-empty SHA. Trigger a
   workflow_dispatch on `deploy-production.yml` with the `target_app`
   input pointed at the new environment's app. Inspect the workflow
   log: `prev modal commit: <sha>` should appear non-empty.
6. **What the first auto-rollback looks like.** The first deploy that
   fails the SLO gate fires a rollback against the bootstrap tag's
   SHA. Modal accepts the redeploy of identical-or-near-identical code
   (modal deploy is idempotent w.r.t. revisioning). Subsequent
   rollbacks always have a real previous deploy to point back at.
7. **Cleanup.** After the second successful deploy stamps a real
   `main-<sha>` tag (via `tag-main.yml`), the `main-bootstrap` tag is
   no longer the second-newest tag and stops affecting
   `record-prev-state`. The tag itself can stay in the repo (cheap)
   or be deleted (`git push origin :main-bootstrap` then
   `git tag -d main-bootstrap`).
8. **Cross-references.** Link to `manual-rollback.md`,
   `migration-recovery.md`, `vision-service-rollback.md`.

### Cross-link from `issues/137-rollback-action-composite.md`

The "Bootstrap edge case (Modal target)" section of Issue #137 already
contains the bootstrap one-liner. Add a forward-link from that section
to the new runbook so the bootstrap procedure has one canonical home.

## Reviewer Context

- The `git rev-parse main^` part of the one-liner assumes the operator
  is on the `main` branch locally. If checking out another branch,
  substitute the appropriate ref.
- The bootstrap tag does NOT replace `tag-main.yml`. That workflow
  continues to stamp `main-<sha>` on every merge to `main`; the
  bootstrap tag just provides a synthetic predecessor for the first
  deploy.
- Modal deploy is idempotent: redeploying the exact same code as a
  rollback target is harmless. Modal cycles a new revision pointing at
  identical artifacts. No special cleanup needed on the Modal side.

## Definition of Done
- [ ] `docs/runbooks/bootstrap-prod-environment.md` created with all
      sections above.
- [ ] Cross-link added from `issues/137-rollback-action-composite.md`
      "Bootstrap edge case (Modal target)" section to the new runbook.
- [ ] `just verify` passes (no code change).

## Dependencies
Issue #137.

## Agent Assignment
platform-agent.

## Progress Notes
2026-04-29: Filed as a follow-up to Phase 6 of #137. The bootstrap
procedure is currently inline in `issues/137-rollback-action-composite.md`
(section "Bootstrap edge case (Modal target)") but has no canonical
runbook home. This issue creates that home so future operators don't
need to read a closed issue's prose to find a one-time procedure.
