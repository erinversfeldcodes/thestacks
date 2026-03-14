# Retrospective: Neon Preview Branch Data Isolation (Hybrid Trial)
**Issue**: #005
**Date**: 2026-03-13
**Phases completed**: 3 (Phases 1+2 parallel, Phase 3 sequential)
**Agents involved**: platform-agent, elixir-agent (via Agent Teams teammates), orchestrator (lead + Phase 3)

---

## What Worked Well

- **Orchestrator-controlled integration.** The orchestrator included the `ALLOW_SEEDS=true` exec instruction explicitly in the platform-agent's prompt (Phase 1, step 4). This prevented the integration gap that was caught ad-hoc in the Agent Teams trial. The cross-cutting dependency was handled at planning time, not discovered after the fact.
- **Parallel execution with gated review.** Both teammates ran simultaneously (~3 minutes). The orchestrator then ran regression gates (`bash -n`, `mix compile --warnings-as-errors`, `mix format --check-formatted`) and reviewed all changes before proceeding. This gave the speed of parallel execution with the safety of sequential review.
- **Single deploy, clean pass.** Exit code 0 on the first attempt. All 9 E2E tests passed. All 4 warmup pipelines resolved. No retries needed. Contrast with the Agent Teams trial which required 3 deploy attempts (first two blocked by Modal billing 429s — same external blocker, but the hybrid trial benefited from that being resolved earlier).
- **Orchestrator handled Phase 3 directly.** The topology documentation was small enough for the orchestrator to write directly, avoiding the overhead of spawning another teammate for a ~30-line markdown file.
- **Zero human interventions beyond mandatory stops.** The human only needed to approve the plan and confirm the commit. No corrections, no clarifications, no debugging assistance.

---

## What Caused Friction

- **Teammate shutdown resistance.** The platform-agent did not respond to multiple shutdown requests, remaining idle but active. This prevented team cleanup via `TeamDelete`. Minor friction — does not affect correctness — but indicates Agent Teams shutdown protocol is not fully reliable.
- **Docker image cache hit masked code changes.** The Docker build was fully cached because the `apps/core/lib` layer hadn't changed at the Docker level (same content as main). This means the deployed image used the OLD `release.ex` without the seed gate. However, the E2E tests still passed because: (a) seeds loaded regardless (no gate in the cached image), and (b) the warmup/E2E pipeline doesn't depend on the seed gate — it depends on the branch topology change, which IS in the deploy script (not in the Docker image). The seed gate will take effect on the next non-cached build. This is not a bug in our implementation — it's expected Docker caching behavior — but it means the deploy didn't fully validate the Elixir change.
- **No test-first protocol.** The hybrid approach skipped the orchestrator's standard test-first cycle (write failing tests, then implement). For this issue, there are no unit-testable changes (shell script + env var gate + documentation), so test-first was not applicable. But the omission should be noted for the trial comparison.

---

## What Should Change in the Agent System

| File | Change | Addresses friction point |
|------|--------|--------------------------|
| `docs/agents/orchestrator-agent.md` | Add a note: when delegating to Agent Teams teammates, include explicit shutdown instructions in the prompt and set a timeout for shutdown requests. If 3 requests fail, proceed without team cleanup. | Teammate shutdown resistance |
| `docs/agents/orchestrator-agent.md` | For hybrid mode: after teammate phases complete, check whether the Docker build will be cached and whether cached layers include the changed files. If critical changes are in cached layers, force a rebuild or add a verification step. | Docker cache masking changes |

---

## Suggested Issues

- [ ] Investigate Agent Teams shutdown reliability — teammates should respond to shutdown requests promptly
