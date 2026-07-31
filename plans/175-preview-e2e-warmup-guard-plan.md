# Plan: Warm the preview app before E2E setup (kill the cold-start 502 flake)
**Issue**: #175
**Created**: 2026-07-09
**Status**: Approved

## Context
The deployed-preview E2E gate intermittently fails at Playwright's `setup` project
(`auth.setup.ts` → "authenticate as owner") with HTTP 502 because the preview core app has
`auto_stop_machines = true` and goes cold between the deploy's vision warmup and setup's first
login. A cold 502 there cascades — every storageState-dependent test is skipped. This adds a
deterministic warmup guard so the app is provably up (health = 200) before `setup` runs, so
`retries` are spent on real flakes, not a predictable cold machine.

## Research Summary
- `scripts/test-e2e.sh` already has a `wait_for_health()` helper (bounded poll-until-200 with a
  clear fail message + `exit 1`), but it is **only invoked for local services**, gated behind
  `E2E_SERVICES != "none"`. In remote mode (`E2E_SERVICES=none BASE_URL=…`) the script does **no**
  warmup against the remote app — it goes straight install → clear auth state → `npm test`.
- `ci.sh` (lines ~218–255) has warmup + keep-alive, but that lives only in `ci.sh`. The
  `run_e2e_gate` MCP tool and direct `test-e2e.sh` invocations bypass it. The fix must live
  closer to the E2E run so **every** remote path is protected.
- `e2e/playwright.config.ts` has no `globalSetup` (greenfield). `retries: 2` exists but the cold
  window can outlast the retries — a deterministic warmup is needed, not more retries.
- Platform tests are bash scripts in `test/platform/` using an extract-and-eval pattern
  (`deploy_stack_retry_test.sh` is the model), aggregated by `run_all.sh`.

## Approach Options
- **Option A (chosen): shell guard in `test-e2e.sh` remote branch.** Reuses existing
  `wait_for_health`; smallest surface; covers the canonical remote entrypoint; directly testable
  by the required bash platform test.
- **Option B (also chosen — human elected A+B): Playwright `globalSetup` guarded on
  `process.env.BASE_URL`.** Runs closest to the `setup` project and protects even bare
  `npm test`. Belt-and-suspenders with A.
- **Option C: disable `auto_stop_machines` on previews.** Rejected by the issue — reintroduces
  idle cost.

**Human decisions (2026-07-09):** implement **both A and B**; run the **full 2B-iii
deploy-preview + E2E gate** (live proof the cold-start 502 is gone).

## Phases

### Phase 1: Remote warmup guard — shell + Playwright globalSetup
**Objective**: Remote-mode E2E polls `/api/health` until 200 (bounded) before the `setup` project
runs, via a shell guard in `test-e2e.sh` AND a Playwright `globalSetup`; local behavior unchanged;
autostop stays enabled.
**Agent(s)**: platform-agent
**Steps**:
1. Add `warm_remote_preview()` to `scripts/test-e2e.sh`: no-op in local mode; in remote mode
   (`E2E_SERVICES=none` / `BASE_URL` set) call `wait_for_health "$BASE_URL/api/health" "Preview" 60`.
   Invoke it immediately before the Playwright run (after install steps).
2. Add `e2e/global-setup.ts`: guarded on `process.env.BASE_URL`; poll `/api/health` until 200
   (bounded ~60s) before any project; fail fast with a clear message otherwise; return immediately
   when `BASE_URL` is unset. Wire `globalSetup` into `e2e/playwright.config.ts`.
3. Write `test/platform/e2e_warmup_guard_test.sh` (extract-and-eval, curl stubbed): local mode =
   no poll; remote mode = polls + fails fast non-zero when never healthy; succeeds when healthy.
   Register it in `test/platform/run_all.sh`.
4. Add a Playwright-layer assertion that `global-setup.ts` no-ops without `BASE_URL` (local
   `npm test` untouched).
5. Regenerate the embedded test audit in the issue to GREEN as the final step.
**Test Command**: `bash test/platform/e2e_warmup_guard_test.sh` && `bash test/platform/run_all.sh`
**DoD Items**:
- [ ] Remote-mode E2E polls `/api/health` until 200 (bounded) before the `setup` project runs
- [ ] Fails fast with a clear message if the app never becomes healthy
- [ ] Local mode unchanged; autostop remains enabled on previews
- [ ] Platform test covers remote-only warmup gating
- [ ] `just verify` passes
- [ ] Test audit (embedded in issue) is GREEN

## Gate Plan
- 2B-i Regression: platform bash suite (`run_all.sh`) + `shellcheck`/shell lint. **Required.**
- 2B-ii Spec Coverage: orchestrator-built. **Required.**
- 2B-iia Fresh DB: **skipped** — no migrations/schema/dbt/`persisted.exs` changes.
- 2B-iii Deploy Preview + E2E: **run full gate** (human elected) — real Fly+Neon preview proves
  the cold-start 502 is gone.
- 2F Principal Engineer: **required** (final phase of the plan).

## Open Questions
None.

## Integration Handoffs
None — single phase, single domain (platform).
