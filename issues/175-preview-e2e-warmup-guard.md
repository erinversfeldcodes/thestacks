# Issue #175: Warm the preview app before E2E setup (kill the cold-start 502 flake)

## Summary
The deployed-preview E2E gate intermittently fails at the Playwright `setup` project (`auth.setup.ts` → "authenticate as owner") with `HTTP 502` because the preview core app has `auto_stop_machines = true` and goes cold between the deploy's vision warmup and the moment Playwright's setup makes its first login request. A cold 502 there cascades — every storageState-dependent test is skipped ("did not run"). Add a warmup guard so the app is provably up before setup runs.

## User Stories
None — E2E harness / CI robustness (serves the "stable, no false failures" bar).

## Goal
The preview-E2E gate never fails or skips due to a cold-start 502 at setup: the harness polls `/api/health` until the app answers 200 (with a bounded timeout) before the `setup` project's first login, so `retries` are spent on real flakes, not on a predictable cold machine.

## Scope Check
- One script / CI step (`scripts/test-e2e.sh` and/or the `deploy-preview` job) + optionally the Playwright `globalSetup`. < 100 LOC, single concern. No split.

## Wiring
- [x] Implementation only (test harness / CI). No app-facing wiring.

## Technical Requirements
1. Before Playwright's `setup` project runs against a remote `BASE_URL`, poll `GET $BASE_URL/api/health` until HTTP 200 (bounded, e.g. ~20 attempts × 3s = 60s) and fail fast with a clear message if it never comes up. Put this in `scripts/test-e2e.sh` (remote-mode branch) and/or a Playwright `globalSetup` guarded on `process.env.BASE_URL`.
2. Root cause is `auto_stop_machines = true` on the preview core app: a machine that autostopped after the deploy warmup returns 502 on the first cold request. Warming via `/api/health` (which the router serves cheaply and which does not autostop-exempt) forces a wake before the auth login. Confirm the health route wakes the machine (Fly replays the request after cold-start; verify a single 200 is sufficient, else loop until stable).
3. Do NOT disable autostop on previews (that reintroduces idle cost — the very thing we're avoiding). The warmup ping is the cheap fix.
4. Keep local (`BASE_URL` unset / localhost) behavior unchanged — no warmup needed there.

## Reviewer Context
- Observed live on preview `stacks-core-pr-feat-loc124a` (Issue #124 Phase 3): setup 502 blocked 15 tests; a manual pre-E2E `curl /api/health` loop (6×) resolved it on the next run.
- `retries: 2` (CI) already exists but did not save setup — the cold window can outlast the retries, so a deterministic warmup is needed, not just more retries.
- Vision warmup during deploy does NOT keep the core app warm through the Playwright-install gap (~30–60s) that precedes setup.

## Test Audit

_Compact audit for a test-harness change — most layers n/a (no app/US surface). Baseline generated 2026-07-08; regenerated GREEN 2026-07-09 after implementation._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Platform / CI harness | yes | ✅ warmup guard runs before `setup` (remote-only) and fails fast if the app never becomes healthy — covered by 3 platform suites + live 2B-iii gate |
| 1–13 (app/US layers) | no | n/a — no application behavior changes |

### Punch list (resolved)
| # | What's needed | Where | Status |
|---|---------------|-------|--------|
| 1 | Health-poll-until-200 before `setup` in remote mode | `scripts/test-e2e.sh` `warm_remote_preview()` + `e2e/global-setup.ts` (wired in `playwright.config.ts`) | ✅ |
| 2 | Bounded timeout + clear fail message if never healthy | Guard A reuses `wait_for_health` (60s bound, `exit 1`); Guard B bounded `attempts × interval` then throws | ✅ |
| 3 | Platform test asserting the warmup runs only in remote (`BASE_URL`) mode | `test/platform/e2e_warmup_guard_test.sh` (11/0), `e2e_global_setup_guard_test.sh` (7/0), `e2e_global_setup_behavior_test.sh` (13/0) | ✅ |

### Verdict
**GREEN.** Both guards gate on `BASE_URL` (no-op locally), poll `/api/health` until 200 before `setup`, are bounded, and fail fast with a clear message. Remote-only gating is regression-locked by `e2e_warmup_guard_test.sh`; Guard B behavior is mutant-tested. Proven live on preview `stacks-core-pr-175-preview-e2e-warmup-guard.fly.dev`: 184 passed / 2 flaky (vision, orthogonal) / 0 failed, with the `setup` project authenticating with zero cold-start 502.

## Definition of Done
- [x] Remote-mode E2E polls `/api/health` until 200 (bounded) before the `setup` project runs
- [x] Fails fast with a clear message if the app never becomes healthy
- [x] Local mode unchanged; autostop remains enabled on previews
- [x] Platform test covers remote-only warmup gating
- [x] `just verify` passes
- [x] **Test audit (embedded above) is GREEN** — applicable cell `✅`; 0 `❌`/`⚠️`. Regenerate as the final step.

## Dependencies
- None. Independent of #124/#173/#174; improves the gate all of them run through.

## Agent Assignment
platform-agent.

## Progress Notes
- 2026-07-08: Raised from #124 Phase 3 — the deployed-preview E2E setup hit a Fly-autostop 502; a manual warmup ping fixed it. This makes that fix permanent in the harness.
- 2026-07-09: Implemented via orchestrator (platform-agent). Two guards: `warm_remote_preview()` in `scripts/test-e2e.sh` + `e2e/global-setup.ts` (Playwright globalSetup), both gated on `BASE_URL`. TDD (RED→GREEN); testing-coordinator gate caught + fixed a real timing defect (attempt-count bound with no delay → no real wait) and added a behavioral mutant-killing test. platform-reviewer caught + fixed a gating bug (`E2E_SERVICES=none` without `BASE_URL` hung 60s). Gates: just verify exit 0; 3 platform suites 11/0·7/0·13/0; live 2B-iii deploy-preview E2E 184 passed/2 flaky/0 failed with zero setup 502. PE gate GREEN. Follow-up filed: `deploy-stack.sh` Neon-branch-lookup error-swallowing (out of scope).
