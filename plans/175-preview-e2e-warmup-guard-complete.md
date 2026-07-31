# Issue #175 — Complete

**Issue**: #175 — Warm the preview app before E2E setup (kill the cold-start 502 flake)
**Branch**: `175-preview-e2e-warmup-guard` (off `main`)
**Commit**: `4a22a25` — test: warm preview app before E2E setup to kill cold-start 502 flake
**Completed**: 2026-07-09
**Agent**: platform-agent

## What shipped
Two `BASE_URL`-gated warmup guards that poll `GET $BASE_URL/api/health` until HTTP 200 (bounded)
before Playwright's `setup` project runs, eliminating the Fly-autostop cold-start 502 that was
cascading into skipped storageState-dependent tests:

- **Guard A (shell)** — `scripts/test-e2e.sh` `warm_remote_preview()`: no-op when `BASE_URL` is
  unset; otherwise reuses the existing `wait_for_health "$BASE_URL/api/health" "Preview" 60`
  (60s wall-clock bound, clear fail message, `exit 1`). Called immediately before the Playwright run.
- **Guard B (Playwright globalSetup)** — `e2e/global-setup.ts` (wired via `playwright.config.ts`
  `globalSetup`): no-op when `BASE_URL` unset; otherwise polls `/api/health` until 200 with a real
  wall-clock bound (`attempts × awaited interval`, env-overridable `PREVIEW_WARMUP_ATTEMPTS=20` /
  `PREVIEW_WARMUP_INTERVAL_MS=3000`), throwing a clear URL-naming message on exhaustion.

Both guards gate on `BASE_URL` only (identical predicate), so local `npm test` is untouched and
`auto_stop_machines` stays enabled on previews (the issue explicitly rejected disabling autostop).

## Tests added
- `test/platform/e2e_warmup_guard_test.sh` (11/0) — Guard A remote-only gating (local no-op incl.
  `E2E_SERVICES=none`+no-`BASE_URL`, remote-healthy, remote-never-healthy fail-fast).
- `test/platform/e2e_global_setup_guard_test.sh` (7/0) — Guard B static wiring.
- `e2e/global-setup.behavior.mjs` + `test/platform/e2e_global_setup_behavior_test.sh` (13/0) —
  Guard B behavioral test (runs the real module via Node TS type-stripping + stubbed `fetch`;
  kills inverted-guard and wrong-URL mutants; proves the attempt bound).
- All three registered in `test/platform/run_all.sh`.

## Gate record
- 2A-iv DoD + testing-coordinator: PASS (caught + fixed a real timing defect; added behavioral test)
- 2B-i Regression: PASS — `just verify` exit 0 (2229 Elixir tests); platform suites 11/0·7/0·13/0
- 2B-ii Spec Coverage: PASS — all 4 Technical Requirements evidenced
- 2B-iia Fresh DB: SKIPPED (no DB changes)
- 2B-iii Deploy-Preview + E2E: PASS live — 184 passed / 2 flaky (vision, orthogonal) / 0 failed;
  both guards fired; `setup` authenticated with zero 502
- 2C platform-reviewer: APPROVED (after fixing a gating bug it caught)
- 2F Principal Engineer: GREEN — no P0/P1
- 2B-iv Preview cleanup: DONE (core app suspended by design; aux apps + Neon branch destroyed)

Revision cycles: 2 (both from gates catching real bugs — a globalSetup timing defect and a shell
gating hole). Process worked as intended.

## Follow-ups filed
- **#177** — `deploy-stack.sh` masks transient Neon API failures as "parent branch not found"
  (cost one gate retry here). Out of #175's locked scope.

## Notes
- The `issues/175-…md` file was briefly lost when the orchestrator branched off `main` (it was
  tracked only on `feat/124-e2e-auth`); recovered from that branch and included in the changeset.
- `issues/177-…md` remains uncommitted (separate concern) as of close-out.
