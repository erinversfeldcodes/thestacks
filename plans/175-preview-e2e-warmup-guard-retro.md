# Retrospective — Issue #175 (preview-E2E warmup guard)

**Date**: 2026-07-09
**Agent**: platform-agent  ·  **Revision cycles**: 2  ·  **Outcome**: merged, all gates green

## What worked well
- **Gates caught real bugs, not nits.** Both revision cycles came from gates finding genuine
  defects: (1) the testing-coordinator flagged Guard B's static grep test as weak, and probing that
  surfaced a real timing defect — `global-setup.ts` bounded on attempt-count with no inter-attempt
  delay, so it gave a fast-failing cold machine ~no wake time; (2) the platform-reviewer found a
  gating hole where `E2E_SERVICES=none` without `BASE_URL` hung 60s and failed. Neither would have
  been caught by "tests pass."
- **Mutation testing as the non-vacuity proof.** The testing-coordinator (and the orchestrator
  independently) mutated the implementation and confirmed the tests flipped RED — this is what
  distinguished the behavioral Guard-B test from the vacuous static one.
- **The elected full 2B-iii gate paid off.** Running the real deploy-preview E2E proved the fix
  end-to-end (both guards fired live; setup authenticated with zero 502) — the ultimate validation
  a unit test can't give for a "does the cold machine actually wake" claim.
- **Scope discipline.** The `deploy-stack.sh` error-swallowing discovery became issue #177 rather
  than scope creep on #175.

## What caused friction
- **Orchestrator branched off `main` and deleted the issue file.** `issues/175-…md` was tracked
  only on `feat/124-e2e-auth` (the branch the session started on), not on `main`. `git checkout -b
  175-… main` removed it from the working tree. It was silently gone until the PE flagged the
  "audit is GREEN" DoD couldn't be satisfied. Recovered via `git show feat/124-e2e-auth:…`, but it
  cost a detour and could have shipped an issue with a missing file.
- **`deploy-stack.sh` transient-error masking cost a gate retry.** A one-off Neon API blip during
  the `staging` branch lookup was reported as "parent branch not found," aborting the first
  deploy. The branch existed; a retry passed. ~20+ minutes of deploy time lost to a misleading error.
- **Guard B's initial "≈60s bound" was aspirational, not real.** The first implementation's comment
  claimed a 60s window that the code didn't deliver (no awaited delay). The specialist wrote the
  comment describing intent rather than the actual behavior.
- **MCP project-tools server was unavailable** the whole session, so every issue/plan/state read and
  the `run_e2e_gate` had to be done by hand (direct file ops + a hand-rolled deploy+E2E runner).

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `docs/agents/orchestrator-agent.md` (Phase 0 / Phase 1) | Before creating an issue branch off `main`, verify the issue file exists on the base branch; if it's tracked only on the current branch, `git show <src>:issues/NNN-*.md > …` (or branch off the source) BEFORE switching. Add a "confirm issue file present in working tree after branch creation" check. | Issue file was deleted by `checkout -b 175 main`; only caught at the PE gate. |
| `docs/agents/platform-agent.md` (Self-Verification) | When adding a bounded/timed loop, require the completion report to state HOW the bound is enforced (awaited delay vs. per-request timeout vs. wall-clock deadline) and prove it against the *fast-failure* path, not just the hang path. Comments must describe actual behavior. | Guard B's attempt-count bound gave no real wait against connection-refused; comment claimed 60s. |
| `issues/177-…` (new issue) | Fix `deploy-stack.sh` to distinguish Neon API failure from genuine branch absence (+ bounded retry). | First 2B-iii attempt aborted on a transient API blip mis-reported as "branch not found." |
| `docs/agents/testing-coordinator-agent.md` | Keep the mutation-testing step explicit for "static/structural" tests — when a test only greps for token presence, require a paired behavioral test or an explicit WEAK verdict. This worked here; codify it. | TC correctly flagged the static Guard-B test; the behavioral test that killed mutants was the fix. |

## Candidate process issues
- (Filed) #177 — deploy-stack.sh Neon lookup error-swallowing.
- (Consider) An orchestrator preflight that confirms MCP project-tools availability at session start
  and warns when falling back to manual file/git ops.
