# Trial Report: Agent Teams — Issue #005
**Branch**: `trial/005-agent-teams`
**Date**: 2026-03-13
**Evaluator**: Orchestrator (Claude Code lead agent)
**Status**: historical — see `agent-teams-evaluation.md` for the final decision

---

## Approach Taken

The lead agent (orchestrator) created a team named `issue-005` with two teammates:

- **platform-agent** — responsible for `deploy-preview.sh`, `.env.example`, and `docs/deployment/NEON_BRANCH_TOPOLOGY.md`
- **elixir-agent** — responsible for gating `Stacks.Release.seed/0` in `apps/core/lib/stacks/release.ex`

Both teammates were spawned simultaneously with detailed prompts containing the specialist agent role description, the specific changes required, file contents for context, and task IDs to update on completion. The lead managed the shared task list, verified output, caught an integration gap, ran deploy validation, and diagnosed failures.

No formal planning phase was conducted — the lead decomposed the issue into tasks and delegated directly. No reviewer agents were invoked. No worktrees were used (file sets were disjoint by design).

---

## Scoring

### Branch 2: Agent Teams

| # | Measure | Result | Notes |
|---|---------|--------|-------|
| 1 | Correctness | **PASS** | All 7 DoD items satisfied. `deploy-preview.sh` branches from `staging`. Seed call gated behind `ALLOW_SEEDS=true`. `.env.example` and topology doc created. Validated by 3 successful deploys to Fly.io with E2E and security testing. |
| 2 | Revision cycles | **0** | Neither teammate was sent back. Both produced correct, passing code on first attempt. |
| 3 | Human interventions | **1** | The human corrected the orchestrator's misattribution of E2E failures to "known flaky tests" — this prompted the Neon MCP database diagnostic that revealed the actual cause (Modal billing 429). The orchestrator's `ALLOW_SEEDS` integration fix was self-initiated and does not count. |
| 4 | Mandatory stop fidelity | **PASS (qualified)** | The lead paused for human review before committing. No teammate continued working during human review. However, this was enforced by the lead's prompting, not by any native Agent Teams mechanism. If the lead had not explicitly managed the stop, there is no guarantee the team would have paused. |
| 5 | Wall-clock time | **~2h 10m** | Implementation: ~6 minutes (18:50–18:56). Verification: ~2h 4m (three deploy cycles). The verification time was dominated by an external blocker (Modal billing limit, HTTP 429) that caused the first two deploys to fail. The third deploy validated the full pipeline. For a fair comparison, implementation time alone was ~6 minutes. |
| 6 | Context window efficiency | **Medium-high** | Three context windows (lead + 2 teammates). Teammate contexts were small and focused (~1 file each). The lead's context grew large due to deploy output, Neon MCP queries, and diagnostic investigation. The distributed model helped keep teammate contexts lean, but the lead still accumulated significant context from the verification phase. |
| 7 | File conflict safety | **PASS** | Zero file overlap between teammates. platform-agent touched `deploy-preview.sh`, `.env.example`, `NEON_BRANCH_TOPOLOGY.md`. elixir-agent touched only `release.ex`. No worktrees were needed because the task decomposition ensured disjoint file sets. This is a property of the task structure, not a guarantee from Agent Teams — with overlapping file sets, conflicts would be possible since teammates share a single working directory. |
| 8 | State recoverability | **FAIL** | If the session were interrupted during teammate execution, partially written files would remain on disk with no state tracking. The TaskList provided coordination state during the session but does not survive restart. The state-complete.json was written post-hoc by the lead, not maintained incrementally during execution. Agent Teams has no native session resumption — `/resume` would not restore the team or its progress. |
| 9 | Code quality (1–5) | **Pending human assessment** | Objectively: `bash -n` passes, `mix compile --warnings-as-errors` passes, `mix format --check-formatted` passes. Code is minimal and focused — no unnecessary changes, no scope creep. The `ALLOW_SEEDS` integration gap was caught by the lead before deployment. No reviewer agent was invoked (a deviation from the standard protocol). |
| 10 | Auditability (1–5) | **Pending human assessment** | The conversation log records the full sequence of events. The TaskList tracked task status. Teammate completion messages were visible to the lead. However: (a) teammates' internal reasoning is opaque — only final output is visible, (b) the diagnostic investigation (Neon MCP queries) was ad-hoc rather than following a structured protocol, (c) the retro and state-complete files provide a post-hoc record but were not maintained during execution. |

---

## Theoretical Expectations vs. Actual Results

| Dimension | Pre-trial expectation | Actual result | Assessment |
|-----------|----------------------|---------------|------------|
| Mandatory stop fidelity | Risk — no team-wide pause | PASS (qualified) — lead enforced stops manually | Better than expected, but fragile |
| Specialist isolation | Shared directory (risk) | PASS — disjoint file sets by task design | Better than expected for THIS issue; would not generalize to overlapping files |
| Context efficiency | Best (distributed) | Medium-high — teammates lean, lead heavy | Worse than expected; lead accumulated significant diagnostic context |
| Session resumption | Teammates lost on resume | FAIL — confirmed | As expected |
| Parallel execution | Best (native) | Good — teammates ran simultaneously in ~4 min | Met expectations |
| Stability | Low (experimental) | Stable — no crashes, clean shutdown | Better than expected |

---

## Key Observations

### What Agent Teams Added

1. **True parallel execution.** Both teammates ran simultaneously and completed in ~4 minutes. The lead didn't need to wait for one to finish before starting the other.
2. **Clean context separation.** Each teammate had a focused context with only the files and instructions relevant to its task. No risk of context window exhaustion from unrelated information.
3. **Task list as coordination primitive.** The shared task list gave the lead visibility into teammate progress without polling or manual status checks.

### What Agent Teams Lacked

1. **No integration verification.** Neither teammate knew about the other's work. The `ALLOW_SEEDS` integration gap — where the elixir-agent gated seeds but the platform-agent's deploy script still called `seed()` without the flag — was only caught because the lead read both outputs and understood the cross-cutting dependency. Agent Teams provides no mechanism for teammates to review or validate each other's work.
2. **No structured review.** The standard orchestrator protocol invokes reviewer agents after implementation. Agent Teams has no equivalent — the lead must manually verify quality. In this trial, no reviewer was invoked; quality was verified by the lead + deploy testing.
3. **No state persistence.** If this session had been interrupted after teammate completion but before the lead's verification, there would be no way to resume without re-reading all changed files and reconstructing context manually.
4. **No mandatory stop enforcement.** The lead chose to pause for human approval. Nothing in Agent Teams prevents a teammate from continuing to work or the lead from proceeding without human sign-off.

### The Integration Gap Problem

The most significant finding is the `ALLOW_SEEDS` integration gap. This is a class of problem that arises specifically in parallel multi-agent execution: two agents make locally correct changes that are globally incorrect when combined. The standard orchestrator protocol (sequential phases with explicit handoffs) would likely have caught this during the implementation of the second phase, because the single context window would contain both the deploy script and the release module changes.

Agent Teams distributes context across teammates, which improves efficiency but creates blind spots at integration boundaries. The lead must actively look for these gaps — they are not surfaced automatically.

---

## Comparison Notes for Scoring Protocol

Per the scoring protocol:
- **Binary measures (4, 7, 8):** Measure 8 (State Recoverability) is a **FAIL**. Per the decision rule, this eliminates the branch unless the failure is "attributable to a fixable bug rather than a design limitation." This is a **design limitation** of Agent Teams — there is no built-in session resumption for teams. It is not fixable by the user.
- **Quantitative measures (1–6):** Strong on revision cycles (0) and implementation speed (~6 min). Wall-clock time inflated by an external blocker (Modal billing), which should be discounted in comparison.
- **Qualitative measures (9–10):** Pending human assessment.

---

## Summary

Agent Teams delivered the implementation quickly and cleanly for this well-scoped, cleanly-separable issue. The parallel execution was genuine and effective. However, the approach has structural weaknesses: no integration verification between teammates, no state persistence, and no enforced mandatory stops. The `ALLOW_SEEDS` integration gap — caught by the lead, not by the system — illustrates the risk of distributing context without a mechanism to verify cross-cutting correctness.

For the evaluation's decision rule, the FAIL on State Recoverability (Measure 8) is a design limitation that cannot be fixed by configuration or prompting. Whether this is disqualifying depends on how heavily the human weights recoverability against the speed and parallelism benefits.
