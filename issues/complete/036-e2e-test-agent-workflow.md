# Issue #036: E2E Test Gate in Agent Workflow

## Summary
The current orchestrator flow is plan → write failing tests → implement → verify tests pass → review. This issue extends it to plan → write failing tests → implement → verify tests pass → **deploy preview → run E2E tests against real infra** → review. This eliminates the class of failures where unit tests pass locally but the feature breaks against real infrastructure (database, vision sidecar, network).

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
CI stops catching "unit tests don't adequately mimic reality" failures. After unit/integration tests pass and before the reviewer assesses the implementation, a preview environment is deployed and E2E tests run against it. The reviewer then receives both the unit test results and the E2E results, and can assess whether test coverage is meaningful against real infrastructure. Revision cycles caused by local-only testing gaps are eliminated.

## Technical Requirements

### 36.1 — Orchestrator Phase Protocol Change

The orchestrator's implementation cycle (Phase 2 in `docs/agents/orchestrator-agent.md`) gains an E2E gate between the regression gate (2B-i) and review (2C):

Current flow:
1. Delegate test writing (2A-i)
2. Failing test gate (2A-ii)
3. Delegate implementation (2A-iii)
4. Automated regression gate (2B-i) — unit/integration tests pass
5. Spec coverage gate (2B-ii)
6. Delegate review (2C)

New flow:
1. Delegate test writing (2A-i)
2. Failing test gate (2A-ii)
3. Delegate implementation (2A-iii)
4. Automated regression gate (2B-i) — unit/integration tests pass
5. Spec coverage gate (2B-ii)
6. **Deploy preview (2B-iii)** — deploy to Fly.io preview app with Neon preview branch
7. **E2E test gate (2B-iv)** — run Playwright E2E tests against the preview URL
8. Delegate review (2C) — reviewer receives unit test results AND E2E results

### 36.2 — Preview Deploy Step (2B-iii)

After the regression gate passes, the orchestrator triggers a preview deployment:

1. Create or reset a Neon preview branch for the issue (using existing `scripts/neon-branch.sh` or Neon MCP tools)
2. Deploy the current branch to a Fly.io preview app (using `scripts/deploy-preview.sh` or equivalent from #004)
3. Wait for health check at `/api/health` on the preview URL
4. If deploy fails: report failure to the specialist for diagnosis. This counts as a revision cycle.
5. Record the preview URL in the state file for the current phase

The preview environment must have:
- Neon preview branch with seeded test data (not empty — #005 addressed data isolation)
- Vision sidecar deployed (or mocked if the phase doesn't touch vision)
- All required secrets configured (from Fly.io secrets)

### 36.3 — E2E Test Gate (2B-iv)

Once the preview is healthy, run Playwright E2E tests against it:

1. Run `E2E_BASE_URL=<preview-url> npx playwright test` from `frontend/`
2. E2E tests from #012 run against real API responses (no `page.route()` mocking)
3. Additional E2E tests specific to the current phase's DoD items may be written by the specialist during the test-writing step (2A-i) — these are tagged with the phase number
4. **If all E2E tests pass:** proceed to review (2C) with E2E results attached
5. **If E2E tests fail:** return failures to the specialist with the preview URL for debugging. This counts as a revision cycle. The specialist can SSH into the preview or check logs via `fly logs`
6. If revision cycle limit (2) is reached, stop and consult human

E2E failures that are clearly environmental (flaky network, cold start timeouts) should be retried once before counting as a revision cycle. The orchestrator makes this judgment call.

### 36.4 — Reviewer Receives E2E Evidence

The reviewer prompt (2C) is updated to include:

- Unit/integration test results (existing)
- **E2E test results against real infrastructure** (new)
- The preview URL (so the reviewer can manually verify if desired)

The reviewer gains a new check:

> **E2E Coverage Assessment**
> - Do the E2E tests exercise the feature against real infrastructure?
> - Are there gaps where unit tests pass but E2E tests would catch regressions?
> - Is the E2E test coverage proportional to the feature's risk?

This is advisory, not a blocker — the reviewer flags E2E coverage gaps as suggestions, not NEEDS_REVISION.

### 36.5 — Preview Cleanup

After the phase is complete (approved and committed):
- Tear down the Fly.io preview app (or leave it for the next phase if more phases remain)
- Delete or reset the Neon preview branch
- Remove the preview URL from the state file

On issue completion (#035 capstone or final phase), ensure all preview resources are cleaned up.

### 36.6 — E2E Test Authoring During Test-First Step

The specialist's test-writing step (2A-i) is extended:

> In addition to unit/integration tests, write any E2E tests needed for this phase's DoD items. E2E tests go in `frontend/e2e/` and are tagged with the issue and phase number. E2E tests written at this stage should test against real API responses (no mocking). They will initially fail because the feature doesn't exist yet — this is expected.

Not every phase needs new E2E tests. The existing smoke tests from #012 provide baseline coverage. New E2E tests are only needed when the phase introduces user-facing behaviour that unit tests can't adequately verify (file uploads, multi-step flows, real database interactions, vision pipeline).

## Definition of Done

- [ ] Orchestrator protocol updated with deploy preview step (2B-iii) and E2E test gate (2B-iv)
- [ ] Deploy preview scripting works from orchestrator context (Fly.io preview + Neon branch)
- [ ] E2E tests can run against a configurable `E2E_BASE_URL` (not just localhost)
- [ ] Reviewer prompt updated to include E2E results and E2E coverage assessment
- [ ] Preview cleanup documented and scripted
- [ ] Specialist test-writing prompt updated to include optional E2E test authoring
- [ ] State file schema updated with `preview_url` field per phase
- [ ] At least one real phase run under the new protocol demonstrating the full flow

## Dependencies
- Issue #004 (platform deployment — preview deploy scripts must exist)
- Issue #005 (Neon preview branch data isolation)
- Issue #012 (Playwright E2E — base E2E test suite must exist)
- Issue #018 (test-first workflow — this issue extends that protocol)

## Agent Assignment
- **platform-agent** for orchestrator protocol changes and deploy scripting
- **elm-agent** for E2E test configuration (configurable base URL)
- All specialist and reviewer doc updates are mechanical

## Progress Notes
<!-- Updated by agents during execution -->
