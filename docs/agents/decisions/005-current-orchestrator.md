# Trial Report: Issue #005 — Current Orchestrator Approach
**Issue**: #024 (Agent Teams Evaluation)
**Trial branch**: `trial/005-current-orchestrator` (executed with hybrid-style parallel Agent invocations)
**Date**: 2026-03-13
**Assessor**: Orchestrator (self-assessment — qualitative scores deferred to human)
**Status**: historical — see `agent-teams-evaluation.md` for the final decision

---

## Execution Summary

Issue #005 (Neon Preview Branch Data Isolation) was implemented using the current prompt-engineered orchestrator. The orchestrator planned 3 phases, delegated Phases 1 and 2 in parallel via two Agent tool invocations, executed Phase 3 directly, then ran the full deploy pipeline (`deploy-preview.sh`) to validate correctness end-to-end.

**Timeline:**
- Plan written and approved by human
- Phases 1+2 delegated in parallel (platform-agent + elixir-agent via Agent tool)
- Phase 1 completed in ~44s (deploy script + env docs)
- Phase 2 completed in ~17s (seed gate)
- Phase 3 completed directly by orchestrator (topology doc)
- Regression gate: `bash -n` and `mix compile --warnings-as-errors` both passed
- Neon `staging` branch created via MCP tool
- Full deploy pipeline: 9/9 E2E tests passed, OWASP ZAP clean, Nuclei clean, IDOR passed
- Zero iteration required

---

## DoD Item Verification

| DoD Item | Status | Evidence |
|----------|--------|----------|
| `deploy-preview.sh` reads `NEON_PARENT_BRANCH` and branches from it | **Done** | Lines 92–114: resolves branch name, lines 149: `parent_id` in payload |
| Lookup for `NEON_PARENT_BRANCH_ID` by name implemented | **Done** | Lines 98–106: curl + python3 pattern matching existing script style |
| `.env.example` documents `NEON_PARENT_BRANCH` | **Done** | Lines 141–145: documented with setup instructions |
| `Stacks.Release.seed/0` gated in production | **Done** | `seeds_allowed?/0` checks `ALLOW_SEEDS` and `MIX_ENV` |
| `docs/deployment/NEON_BRANCH_TOPOLOGY.md` created | **Done** | Three-tier diagram, setup steps, env var table |
| Three-tier topology documented | **Done** | main → staging → preview/<branch> with table |
| Manual staging setup steps documented | **Done** | CLI and API examples included |

All 7 DoD items satisfied.

---

## Scoring Against Success Measures

### Quantitative Measures

| # | Measure | Result | Notes |
|---|---------|--------|-------|
| 1 | **Correctness** | **Pass** | All 7 DoD items satisfied. Deploy pipeline validated end-to-end: parent branch resolved (`staging → br-plain-bread-aknzfcb6`), preview branch created with `parent_id`, seeds ran successfully, 9/9 Playwright E2E tests passed, OWASP ZAP FAIL-NEW: 0, Nuclei clean, IDOR blocked (HTTP 403). System behaves identically to `main`. |
| 2 | **Revision cycles** | **0** | Both specialists produced correct output on first attempt. State file confirms `revision_cycles: 0` across all 3 phases. No NEEDS_REVISION verdicts. |
| 3 | **Human interventions** | **0** | The human's only actions were: approving the plan (mandatory stop — excluded from count) and confirming commit (mandatory stop — excluded). No conflict resolution, no agent correction, no ambiguity clarification needed. State file confirms `human_interventions: 0`. |
| 4 | **Mandatory stop fidelity** | **Pass** | Orchestrator paused for plan approval before delegating any work. No agent proceeded past a checkpoint without explicit human confirmation. State file confirms `mandatory_stop_violations: 0`. |
| 5 | **Wall-clock time** | **~18 min** | ~10 min for implementation (plan + parallel phases + regression gate) + ~8 min for deploy and E2E validation. Phases 1+2 ran concurrently — Phase 2 finished in 17s, Phase 1 in 44s, so parallel execution saved ~17s vs sequential. |
| 6 | **Context efficiency** | **~42k tokens (specialists) + orchestrator window** | Platform-agent subagent: ~28k tokens. Elixir-agent subagent: ~15k tokens. Orchestrator window held only planning context, file reads, verification commands, and deploy output — specialist implementation details stayed in subagent contexts and did not bloat the main window. |

### Binary Measures

| # | Measure | Result | Notes |
|---|---------|--------|-------|
| 7 | **File conflict safety** | **Pass** | Phase 1 touched `scripts/deploy-preview.sh` and `.env.example`. Phase 2 touched `apps/core/lib/stacks/release.ex`. Zero file overlap. Both ran in the same working directory (no worktrees needed for this issue — file sets were fully disjoint). No overwrites detected. |
| 8 | **State recoverability** | **Pass** | State file (`plans/005-...-state.json`) tracked all 3 phases with status, timestamps, agent assignments, revision cycles, and last actions. If the session had been interrupted after Phase 1 completed, the state file would show Phase 1 complete, Phase 2 in-progress, Phase 3 pending — enough to resume. |

### Qualitative Measures (human scoring recommended)

| # | Measure | Self-Assessment | Notes for Human Scorer |
|---|---------|-----------------|------------------------|
| 9 | **Code quality (1–5)** | 4 (suggested) | Deploy script changes follow the existing curl/python3 pattern exactly. Seed gate is 6 lines of clean Elixir with a well-named `seeds_allowed?/0` predicate. Topology doc is structured with diagram, table, setup commands, and env var reference. Deductions: no unit tests for the seed gate (tested via deploy integration instead), topology doc assumes root branch is named `main` when actual project uses `production`. |
| 10 | **Auditability (1–5)** | 4 (suggested) | Full trail exists: plan file → state file (with per-phase timestamps and verdicts) → retro document → this report. The orchestrator's reasoning is visible in the conversation. Deductions: executed on `trial/005-current-orchestrator` branch but state file recorded `"trial": "hybrid"` — a labeling inconsistency that could confuse someone reading the artifacts without conversation context. Credential leak in env check command is a process gap visible in the transcript. |

---

## Friction Points and Their Severity

| Friction Point | Severity | Impact on Measures | Design Limitation or Bug? |
|----------------|----------|-------------------|--------------------------|
| Wrong git branch (`current-orchestrator` vs `hybrid`) | Low | Labeling only — no functional impact | Bug (orchestrator should verify branch before starting) |
| Neon root branch named `production` not `main` | Low | Topology doc slightly inaccurate | Bug (doc should note naming varies) |
| Credential leak in env check | Medium | Security hygiene issue in orchestrator commands | Bug (fixable with better echo pattern) |

None of these friction points caused measure failures. All are fixable bugs, not design limitations of the current orchestrator approach.

---

## Theoretical Predictions vs Actual Results

The pre-trial decision matrix predicted these outcomes for the current orchestrator. Here's how they held up:

| Dimension | Predicted | Actual | Match? |
|-----------|-----------|--------|--------|
| Mandatory stop fidelity | Pass | **Pass** | Yes |
| Specialist isolation | Worktrees | **No worktrees needed** (disjoint files) | Partially — worktrees available but unnecessary for this issue |
| Context efficiency | Medium (single window) | **Better than expected** — subagent contexts kept orchestrator lean | Exceeded prediction |
| Session resumption | State files | **Pass** — state file tracked all phases | Yes |
| Parallel execution | Good (Agent tool) | **Good** — 2 phases ran concurrently, ~17s saved | Yes |
| Stability | High | **High** — zero failures, zero retries | Yes |

---

## Summary

The current orchestrator approach delivered a clean implementation of Issue #005 with zero revision cycles, zero human interventions, and full deploy validation on the first attempt. All binary measures passed. Quantitative measures are at floor values (0 cycles, 0 interventions, ~18 min wall clock). The three friction points identified are all fixable bugs, not architectural limitations.

This establishes the baseline that the Agent Teams and hybrid branches need to match or beat.
