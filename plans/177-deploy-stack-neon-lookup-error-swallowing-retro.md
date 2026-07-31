# Retrospective — Issue #177 (deploy-stack Neon lookup error-swallowing)

**Date**: 2026-07-09 · **Agent**: platform-agent · **Revision cycles**: 2 · **Outcome**: merged into `feat/124-e2e-auth`

## What worked well
- **The fix came from a prior gate's pain.** #177 existed only because #175's 2B-iii gate hit the
  swallowed-Neon-error and the orchestrator+PE flagged it. Closing the loop from "flake observed" →
  "tracked issue" → "fixed" is the process working as intended.
- **Gates caught real gaps again.** The testing-coordinator proved the non-transient-4xx guard was
  silently deletable (removing it reintroduces the exact #177 bug for the expired-key scenario) —
  a genuine coverage hole in the highest-value path. Both reviewers independently flagged the
  branch-name→python interpolation. Neither was a rubber-stamp.
- **Mutation testing as the acceptance bar.** Every "is this test non-vacuous?" question was
  answered by mutating the impl and confirming RED — for the transient retry, the 401 guard, and
  the quote-hardening. This is now a reliable habit.
- **Confirmatory deploy proved the happy path cheaply-enough.** Even though the full deploy failed
  on Fly infra, the log gave decisive evidence the refactored lookup works live (parent resolved,
  branch created) — which was the gate's real purpose.

## What caused friction
- **Fly release-command machine timeout blocked 2B-iii — twice, identically.** ~40 min of deploy
  time spent on a failure entirely unrelated to the change. The confirmatory-deploy gate is only as
  reliable as Fly's release-command lifecycle, which was degraded. This is the second consecutive
  issue (#175 Neon blip, #177 Fly release timeout) where the elected full deploy gate flaked on
  infra rather than testing the change.
- **Stale worktrees accumulated.** Seven `worktree-agent-*` branches/worktrees from abandoned
  feat/124 agent runs, all superseded by feat/124 but holding uncommitted (superseded) edits —
  noise that needed careful "is this unique work?" forensics before it was safe to say "delete".
- **Committing ahead of the reviewer/PE gates** (human-elected) meant the reviewer/PE findings
  (interpolation hardening) landed as a post-commit revision rather than pre-commit — worked out
  fine here because nothing was pushed, but it inverts the intended gate order.
- **Branch-switch-during-deploy hazard.** The merge had to be held because a `git checkout` would
  have reverted `deploy-stack.sh` under the running deploy — a non-obvious footgun when a long
  background deploy overlaps with git operations.

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `docs/agents/orchestrator-agent.md` (2B-iii) | Distinguish "the changed code path failed" from "an unrelated deploy stage failed" when a confirmatory deploy dies. For harness/script changes whose own path is proven live, allow accepting the gate on that basis without N full-deploy retries. Add explicit guidance: an infra failure downstream of the change is not a revision cycle and shouldn't consume repeated ~20-min deploys. | Both #177 2B-iii attempts died at the Fly release-command stage; the Neon fix ran clean both times. |
| `docs/agents/orchestrator-agent.md` (worktree hygiene) | Add a session-start/close step: enumerate `git worktree list`, and for each `worktree-agent-*` check unique-commits + dirty-vs-integration-branch, so stale isolation worktrees are surfaced (not silently accumulated). | 7 stale worktrees found only because the human asked. |
| `docs/agents/orchestrator-agent.md` (Working Tree Hygiene) | Note the branch-switch-during-background-deploy hazard: never `git checkout` a different branch while a long-running deploy/E2E reads working-tree scripts; hold merges until such background work completes. | #177 merge had to be deferred to protect the in-flight deploy. |
| `docs/agents/platform-agent.md` (Self-Verification) | For any shell that interpolates a variable into an inline `python3 -c`/`awk`/`sh -c`, require passing it out-of-band (argv/env) or justifying why not. Would have pre-empted the interpolation finding both reviewers raised. | `${branch_name}` interpolation flagged by platform-reviewer AND PE. |

## Candidate process issues
- (Not filed, per human) **Fly core release-command machine timeout** on preview deploys —
  reproducible, will block #174/#173. Strongly recommend filing if it recurs on the next deploy.
- (Optional) curl `--max-time`/`--connect-timeout` on the Neon lookup (P3, both reviewers).
