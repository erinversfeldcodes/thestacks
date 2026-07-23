# Issue #269: Zero skipped/did-not-run tests in the CI E2E (deploy-preview)

## Summary
The `deploy-preview` "Run E2E against deployed stack" job skips a handful of tests and leaves others
"did not run". Owner directive: **no tests should be skipped in CI.** Make the CI E2E environment
complete enough that every applicable spec runs — no conditional `test.skip`, no aborted-mid-run.

## User Stories
None — CI / test-infra hardening. Validatable: the deploy-preview E2E summary shows `0 skipped, 0 did-not-run`.

## Goal
`deploy-preview` E2E reports `N passed, 0 failed, 0 skipped, 0 did-not-run` (flaky-on-retry allowed
but investigated). Every `test.skip(condition, …)` guard either never triggers in CI (because CI
provides what it needs) or is removed as genuinely-not-applicable with a documented reason.

## Wiring
Implementation only — CI workflow + deploy config + E2E env; no product routes.

## Feature-Completeness Pre-Check
n/a — infra/CI. (Note the canonical-surface + `just ci`-gate lessons already encoded from #119.)

## Findings (local audit 2026-07-21, `feat/119-e2e`)
Full local chromium run: 196 passed, **10 skipped**, 0 failed. Skip inventory by root cause:

1. **Mail (3): `confirm-email.spec.ts:94`, `password-reset.spec.ts:27,62`.** Guard: `emails === null`
   (the `/api/test/sent-emails` helper returns `mailbox_readable:false`). Root cause: the stack ran
   with the **Resend** adapter (`.env` `EMAIL_PROVIDER=resend` → `config/runtime.exs:171`
   `resend_configured?` overrides the `Swoosh.Adapters.Local` default), so the in-memory Local mailbox
   is empty. **Fix:** the CI E2E core stack must run with **Swoosh Local** — do NOT set
   `EMAIL_PROVIDER=resend`/`RESEND_API_KEY` in the E2E deploy env (keep `STACKS_E2E_TEST_HELPERS=1`).
2. **Observability (7): `dashboards.spec.ts:77` ×6 (`!GRAFANA_URL`), `transparency.spec.ts:116`
   (`!E2E_EXPECT_LIVE_METRICS`).** Root cause: no reachable Grafana / no VictoriaMetrics with pushed
   samples. `deploy-preview` DOES stand up Grafana + VM (fewer skips in CI than local), but the E2E
   step needs `GRAFANA_URL` + `E2E_EXPECT_LIVE_METRICS=1` exported AND the datasource healthy with
   samples actually pushed (the core metrics pusher must have run against the preview VM). **Fix:**
   wire those env vars in the `deploy-preview` E2E step + ensure the preview VM has ingested samples
   before E2E runs (or add a warm-up that pushes + waits).
3. **Seed data: 0 skips** — `editions.spec` passed; no seed gap. (Confirmed not a problem.)
4. **Helper-endpoint specs (gdpr/audit-log/privacy-block): all PASSED** — `STACKS_E2E_TEST_HELPERS`
   endpoints work; not a source of skips. (Confirmed not a problem.)

**Separately — the CI "16 did not run"** (not a skip): the preview stack was torn down / auto-stopped
mid-run. Fix the deploy-preview stack **stability** (prevent idle auto-stop during E2E, or ensure the
cleanup trap doesn't fire until E2E completes) so no test is abandoned.

## Technical Requirements
- **Mail:** run the E2E deploy stack with Swoosh Local (unset `EMAIL_PROVIDER`/`RESEND_API_KEY` for
  that stack); the mail specs then read the Local mailbox and run.
- **Observability:** export `GRAFANA_URL` + `E2E_EXPECT_LIVE_METRICS=1` into the `deploy-preview` E2E
  step; ensure the preview VictoriaMetrics has received samples (metrics-push warm-up) so the Grafana
  panels + transparency live-metrics assertions have data.
- **Stability (did-not-run):** keep the preview core VM awake for the E2E duration; the cleanup trap
  must only fire after the run. Investigate the actual CI log for the abort cause.
- **Audit for any remaining `test.skip` in `e2e/tests/*`** — each must either be CI-satisfiable
  (provide what it needs) or removed with a one-line rationale (genuinely-not-applicable in CI).

## Findings from the #116/#280 preview gate (2026-07-23) — stability evidence for the "did-not-run" workstream
Five full-suite runs against a freshly deployed preview (512MB, auto-stop) produced rotating
env-signature failures, each spec green in a sibling run on identical code:
1. **Fresh deploy created a SECOND machine that sat stopped with a failing check** — fly-proxy
   intermittently routed to it → 502 clusters mid-run (fixed for the session by `fly machine
   destroy` of the sick machine; the deploy script should enforce single-machine previews).
2. **Boundary cold-starts:** the machine auto-stops within ~a minute of a run ending, so the next
   run's auth.setup races the wake and 502s even when `/api/health` just passed (warm the POST
   path, e.g. a login probe until 401, not just GET health — a plain health warm was insufficient).
3. **Mid-run 502 blips + 90s navigation timeouts under 4-worker full-suite load** (a run stretched
   9.8m → 14.8m) — the 512MB VM is under-provisioned for the full parallel suite; keep-alive
   during E2E (min_machines_running=1 for the run) or reduced workers likely needed.
Zero `:auth`-bucket failures across consecutive full runs after #280's migration — that class is
closed; the above three are what remains for this issue's stability workstream.

## Reviewer Context
- `deploy-preview` uses `deploy-stack.sh` (full stack incl. Grafana/VM/Modal). `STACKS_E2E_TEST_HELPERS`
  is set on preview. The test helpers are scoped to `@thestacks.test` emails (`test_helper_controller.ex:25`).
- Relates to #258 (email adapter hermeticity) — the Local-vs-Resend adapter is the same lever.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| E2E harness / CI | yes | ❌ deploy-preview E2E has 6–10 conditional skips + did-not-run (→ ✅ when the run reports 0 skipped / 0 did-not-run) |
| 1–13 (app) | no | n/a — CI-environment issue, not app behaviour |

## Definition of Done
- [ ] `deploy-preview` E2E reports **0 skipped** — evidence: CI job summary
- [ ] `deploy-preview` E2E reports **0 did-not-run** (stack stays up for the full run) — evidence: CI summary + no teardown-mid-run
- [ ] Mail specs run (Swoosh Local for the E2E stack) — evidence: confirm-email/password-reset pass in CI
- [ ] Observability specs run (Grafana/VM wired + samples) — evidence: dashboards/transparency pass in CI
- [ ] Any remaining `test.skip` is CI-satisfiable or removed-with-rationale — evidence: grep of `e2e/tests` + CI run
- [ ] `just ci` passes — evidence: command→output

## Dependencies
Surfaced by the #119 PR (#340) deploy-preview run. Independent of #119's product content; can proceed
in parallel / after the #119 merge.

## Agent Assignment
platform-agent + testing-coordinator

## Progress Notes
- 2026-07-21: Filed from the #340 deploy-preview failure investigation. The one real *failure*
  (auth-nav strict-mode locator) was fixed on feat/119-e2e (`89a5e1ea`); this issue tracks the
  skips + did-not-run (CI-environment completeness), per the owner's "no tests skipped in CI".
