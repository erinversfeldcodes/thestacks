# Trial Report: Hybrid — Issue #005
**Branch**: `trial/005-hybrid`
**Date**: 2026-03-13
**Evaluator**: Orchestrator (Claude Code lead agent)

---

## Approach Taken

The orchestrator handled planning, mandatory stops, regression gates, review, and documentation (Phase 3). Agent Teams teammates handled implementation (Phases 1+2 in parallel). This is the "best of both" model: the orchestrator's structured protocol for control flow, with Agent Teams for parallel specialist execution.

**Workflow:**
1. Orchestrator wrote and presented the plan (mandatory stop)
2. Human approved the plan
3. Orchestrator created a team and spawned platform-agent + elixir-agent teammates simultaneously
4. Both teammates completed in ~3 minutes with zero revision cycles
5. Orchestrator ran regression gates: `bash -n`, `mix compile --warnings-as-errors`, `mix format --check-formatted`
6. Orchestrator reviewed all changes, verifying the integration point (`ALLOW_SEEDS=true` in exec)
7. Orchestrator shut down teammates and wrote Phase 3 (topology doc) directly
8. Orchestrator ran `deploy-preview.sh` — exit code 0, all tests passed
9. Mandatory stop for human commit approval

**Key design choice:** The orchestrator included the cross-cutting `ALLOW_SEEDS=true` instruction in the platform-agent's prompt at spawn time. This addressed the integration gap proactively rather than catching it during review (as happened in the Agent Teams trial).

---

## Scoring

### Branch 3: Hybrid

| # | Measure | Result | Notes |
|---|---------|--------|-------|
| 1 | Correctness | **PASS** | All 7 DoD items satisfied. Validated by deploy: 9/9 E2E tests passed, 4/4 warmup pipelines resolved, all security scans clean. Exit code 0. |
| 2 | Revision cycles | **0** | Neither teammate was sent back. Orchestrator regression gates passed on first run. |
| 3 | Human interventions | **0** | Human only acted at mandatory stops (plan approval, commit approval). No corrections, no debugging, no clarifications needed. |
| 4 | Mandatory stop fidelity | **PASS** | Orchestrator paused after plan presentation (waited for "approved"). Orchestrator paused before commit (waited for human). No work proceeded past either checkpoint. The orchestrator protocol enforces this — it is not dependent on Agent Teams behavior. |
| 5 | Wall-clock time | **~15 min** | Plan: ~2 min. Implementation (parallel): ~3 min. Regression gates + review: ~2 min. Phase 3 (docs): ~1 min. Deploy + E2E + security: ~7 min. No retries. |
| 6 | Context window efficiency | **Medium-high** | Three context windows (lead + 2 teammates). Teammates had small, focused contexts. Lead context grew moderately from deploy output but less than the Agent Teams trial (single deploy attempt vs. three). |
| 7 | File conflict safety | **PASS** | Zero file overlap between teammates. Orchestrator decomposed work into disjoint file sets at planning time. No worktrees needed. |
| 8 | State recoverability | **PASS (qualified)** | The orchestrator maintained `plans/005-...-state.json` throughout, updating it at each phase transition. If the session were interrupted, the state file records which phases are complete and what remains. However, the state file is written by the lead — if the lead is interrupted mid-update, the file may be stale. The qualification: teammate work-in-progress would still be lost on interruption (same as Agent Teams), but the orchestrator's state file provides a recovery point that pure Agent Teams lacks. |
| 9 | Code quality (1–5) | **Pending human assessment** | `bash -n`, `mix compile --warnings-as-errors`, `mix format --check-formatted` all pass. Code is minimal and focused. Integration point handled proactively. No reviewer agent was invoked (same as Agent Teams trial — for fair comparison). |
| 10 | Auditability (1–5) | **Pending human assessment** | Full plan file written before implementation. State file updated at each transition. Orchestrator explicitly reported regression gate results and review findings. Teammate reasoning is still opaque (same limitation as Agent Teams). |

---

## Comparison: Hybrid vs. Agent Teams

| Dimension | Agent Teams (Branch 2) | Hybrid (Branch 3) | Winner |
|-----------|----------------------|-------------------|--------|
| Correctness | PASS | PASS | Tie |
| Revision cycles | 0 | 0 | Tie |
| Human interventions | 1 (misattributed failure) | 0 | Hybrid |
| Mandatory stop fidelity | PASS (qualified — lead-enforced) | PASS (protocol-enforced) | Hybrid |
| Wall-clock time | ~2h 10m (Modal blocker) | ~15 min | Hybrid* |
| Context efficiency | Medium-high | Medium-high | Tie |
| File conflict safety | PASS | PASS | Tie |
| State recoverability | FAIL | PASS (qualified) | Hybrid |
| Code quality | Pending | Pending | Pending |
| Auditability | Pending | Pending | Pending |

*Wall-clock time comparison is confounded by the Modal billing blocker affecting the Agent Teams trial. Implementation time was comparable (~6 min vs ~3 min). The hybrid trial benefited from the blocker being resolved earlier.

---

## Key Differences from Agent Teams Trial

1. **Integration gap handled proactively.** The orchestrator included `ALLOW_SEEDS=true` in the platform-agent prompt. In the Agent Teams trial, this was caught ad-hoc after both teammates completed. This is the primary advantage of the hybrid model: the orchestrator has full context of both phases and can embed cross-cutting concerns in the prompts.

2. **Regression gates run by orchestrator.** The orchestrator verified `bash -n`, `mix compile`, and `mix format` before proceeding. In Agent Teams, each teammate self-verified, but there was no central gate.

3. **State file maintained throughout.** The orchestrator updated the state file at each phase transition. Agent Teams had no equivalent — the state file was written post-hoc.

4. **Single deploy attempt.** Clean pass on first try. Agent Teams required 3 attempts (external blocker, but the hybrid trial also ran the same deploy script against the same services).

5. **Zero human interventions.** Agent Teams required 1 (correcting misattributed failure). Hybrid required 0.

---

## Summary

The hybrid approach delivered the best results of the trial: zero revision cycles, zero human interventions, single-attempt deploy validation, and proactive integration gap prevention. It preserved the parallel execution benefit of Agent Teams while adding the orchestrator's structured planning, regression gates, and state management.

The main weakness inherited from Agent Teams is teammate opacity (internal reasoning not visible) and the shutdown reliability issue. The main strength over pure Agent Teams is the orchestrator's ability to embed cross-cutting concerns in prompts and enforce mandatory stops via protocol rather than relying on teammate behavior.
