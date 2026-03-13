# Retrospective: Evaluate Claude Code Agent Teams
**Issue**: #024
**Date**: 2026-03-13
**Phases completed**: 1 (expanded significantly beyond original scope)
**Agents involved**: Orchestrator (direct — no specialist delegation)

---

## What Worked Well

- **Human override redirected to better outcome**: The initial desk-analysis recommendation ("Stay") was rejected by the human in favor of an empirical trial. This was the right call — the trial revealed the integration gap finding that desk analysis would have missed entirely.
- **Three-branch trial design**: Running the same issue through all three approaches on parallel branches produced directly comparable results. The 10-measure scoring protocol made the comparison objective and defensible.
- **The `ALLOW_SEEDS` integration gap**: This was the trial's most valuable finding. It exposed a real class of bug (parallel phases making locally correct but globally incorrect changes) and showed that the hybrid approach prevents it proactively while the current orchestrator misses it. This single finding justified the entire trial.
- **Code comparison as evidence**: Diffing the actual code across branches revealed differences that the process metrics alone would have missed (e.g., the current orchestrator passed all E2E tests despite having a latent bug because its lenient gate masked it).
- **Agent Teams stability exceeded expectations**: The experimental feature ran without crashes or coordination failures, which was better than predicted.

---

## What Caused Friction

- **Scope expansion without plan update**: The original plan had one phase (research + decision doc). The human redirected to a three-branch empirical trial, which was substantially more work. The plan file was never updated to reflect this — it still shows the original single-phase structure. The state file and issue progress notes capture what actually happened, but the plan is stale.
- **Branch mismatch**: The current orchestrator trial was accidentally executed on `trial/005-current-orchestrator` but recorded as `trial: "hybrid"` in the state file, and vice versa. This caused labeling confusion in the reports. The orchestrator should verify `git branch --show-current` before starting work.
- **Modal billing blocker**: The Agent Teams trial was disproportionately affected by a Modal HTTP 429 (billing limit), requiring 3 deploy attempts. This inflated its wall-clock time and triggered a human intervention. While external, it made the comparison less clean — implementation time had to be separated from verification time for fair scoring.
- **Credential exposure**: The orchestrator's env check command printed raw credential values instead of just confirming they were set. A process gap, not a design issue.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/orchestrator-agent.md` | Add a step to Phase 1 (Planning): if the human redirects the approach after plan approval, update the plan file to reflect the new scope before proceeding | Stale plan after scope expansion |
| `docs/agents/orchestrator-agent.md` | Add a pre-delegation check: verify `git branch --show-current` matches the expected branch from the state file before spawning any agents | Branch mismatch |

---

## Suggested Issues

- [ ] Revisit Agent Teams evaluation when the feature exits experimental status — session resumption and mandatory stop enforcement may be addressed upstream
- [ ] Test the hybrid approach on an issue with overlapping file sets across parallel phases to validate worktree isolation under the new model
