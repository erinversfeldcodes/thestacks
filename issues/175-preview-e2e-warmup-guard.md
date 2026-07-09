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

_Compact audit for a test-harness change — most layers n/a (no app/US surface). Pre-implementation baseline generated 2026-07-08. Green when the warmup guard exists and is exercised._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Platform / CI harness | yes | ❌ warmup guard before setup; fails fast if app never healthy |
| 1–13 (app/US layers) | no | n/a — no application behavior changes |

### Punch list (baseline)
| # | What's needed | Where |
|---|---------------|-------|
| 1 | Health-poll-until-200 before `setup` in remote mode | `scripts/test-e2e.sh` (and/or Playwright `globalSetup`) |
| 2 | Bounded timeout + clear fail message if never healthy | same |
| 3 | Platform test asserting the warmup runs only in remote (`BASE_URL`) mode | `test/platform/` |

### Verdict
Baseline — no warmup guard. Green when a remote-mode `BASE_URL` run polls health before setup, is bounded, and a platform test covers the remote-only gating.

## Definition of Done
- [ ] Remote-mode E2E polls `/api/health` until 200 (bounded) before the `setup` project runs
- [ ] Fails fast with a clear message if the app never becomes healthy
- [ ] Local mode unchanged; autostop remains enabled on previews
- [ ] Platform test covers remote-only warmup gating
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — applicable cell `✅`; 0 `❌`/`⚠️`. Regenerate as the final step.

## Dependencies
- None. Independent of #124/#173/#174; improves the gate all of them run through.

## Agent Assignment
platform-agent.

## Progress Notes
- 2026-07-08: Raised from #124 Phase 3 — the deployed-preview E2E setup hit a Fly-autostop 502; a manual warmup ping fixed it. This makes that fix permanent in the harness.
