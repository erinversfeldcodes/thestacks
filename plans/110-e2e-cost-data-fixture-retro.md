# Retrospective: E2E Cost Data Fixture
**Issue**: #110
**Date**: 2026-07-19
**Phases completed**: 1
**Agents involved**: elixir-agent, testing-coordinator, elixir-reviewer, contract-reviewer, principal-engineer, elm-agent (spinoff)

---

## What Worked Well

- **Feature-completeness live drive caught the real risk shape early.** Running the skill (not trusting the issue's "n/a — no user stories") reframed #110 from "a fixture" to "the thing that makes US-5.1 provable," and the local live drive ($11.68 banner) proved the render pipeline before any test was un-conditionalised.
- **The DoD/test-layer sufficiency gate found the missing unit layer.** The as-filed DoD had no test protecting the fixture; the gate produced the 4 protection tests (populate / sum / period-in-window / idempotency) and drove the "logic must be unit-testable" decision — moving the item into `Stacks.Costs.seed_current_period_costs/0` instead of raw rows in seeds.exs.
- **Testing-coordinator caught a vacuous test.** The anti-drift test iterated the already-month-filtered `current_period_costs/0` (empty-loop pass); TC flagged it WEAK → strengthened to query the raw table with `==:eq`. A real defect the happy-path drive would never have shown.
- **The gate sequence surfaced two pre-existing bugs the tree was hiding** (#258 email → real Resend; the dead `AddShelf` Elm lint), and fixing them turned `just verify` fully green for the first time in a while.
- **Reviewers + PE were spot-on and non-blocking** — the DRY drift note (→ #259) and the month-window caveat were correctly triaged as follow-up/acceptable, not scope creep.

---

## What Caused Friction

- **The biggest gap (Finding B) was found mid-execution, not at planning.** The plan's "proving gate" for the DoD item *"preview deploys have cost data immediately after seeding"* was written as a **local** gate (fresh-DB seed → local `/costs`). The real risk — *does the seed actually fire on a deployed preview?* — only surfaced at the 2B-iii deploy gate, when the log printed `Skipping preview seed: seeds.exs matches origin/main`. Root cause: **I validated the read/render path and assumed the write/delivery path.** The fact that determined it (CLAUDE.md: "preview seed only runs when the PR changes seeds.exs") was in context from message one and was never converted into a planning requirement.
- **Local `rpc` seeding was a workaround, not proof.** Because the change was uncommitted at first deploy, the natural seed was skipped; I seeded via `rpc` to get a green E2E. That validated the function on the deployed node but NOT the production path — leaving a real "verified-by-construction, not observed" gap that was only closed by a second redeploy after commit.
- **`just verify` masking:** an early `just run just verify > log; echo` wrapper masked the real exit code (echo→0), briefly reporting a pass that was actually a fail. Cost a re-run.
- **Toolchain path friction:** `just run mix run priv/repo/seeds.exs` failed (just recipes run from repo root) — needed the repo-root-relative path.

---

## What Should Change in the Agent System

1. **`docs/agents/orchestrator-agent.md` — DONE this session (commit `ea081223`).** Added point 5 to the *DoD & Test-Layer Sufficiency Check*: **every runtime/deploy-time DoD item needs a proving-gate at planning naming (a) the real signal, (b) where it's observed at the far end, (c) the preconditions for the mechanism to fire — and if the observation needs a precondition (e.g. a committed change), that's a planning finding, not a mid-execution surprise.** Trace the deliverable's *write/delivery* path, not just its read/render path; sweep its own side-effect telemetry and its temporal/edge behaviour. This is the concrete fix for the Finding-B class.
2. **Orchestrator Bash convention:** never wrap a gate command as `cmd > log; echo "EXIT=$?"` in a foreground/background call — the trailing `echo` masks the real exit. Capture `$?` on the same line as the last meaningful command, or read the exit from the tool result. Candidate for a CLAUDE.md shell-conventions note.
3. **Residual follow-ups to file:** (a) assert the seed's `[:stacks, :costs, :recorded]` telemetry emission (Layer-11 side effect, currently unasserted); (b) the month-boundary edge (rows stamped to seed-time month → `/costs` empties across a boundary until the 06:00 cron) is acknowledged-acceptable but untested — worth a one-line note or a temporal test. Neither blocks #110.

---

## Outcome

#110 complete: all 7 DoD ✅ with evidence, natural production seed path **observed** (redeploy from the committed branch ran `seed_live/0` clean, `/api/costs=1168` with no `rpc`, `costs.spec.ts` 4/4). Spinoffs #258 + #259 also completed in-session. `just verify` fully green. Preview torn down. Not yet pushed.
