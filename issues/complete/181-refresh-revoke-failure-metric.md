# Issue #181: Emit a metric when refresh fails to revoke the old token

## Summary
`AuthController.refresh/2` (#173) revokes the old token before minting a new one; if
`Guardian.revoke/1` errors it logs a `Logger.warning` and **still mints a fresh token**, leaving the
old token live until its TTL. That degraded case is emitted only as a log line — there is no metric,
so a spike (Neon/guardian_db issues, or abuse of the rotation path) is invisible on the dashboards.
Emit telemetry so it's observable and alertable.

## User Stories
None — observability of the auth refresh path (#173).

## Goal
Refresh revoke-failures are counted as a metric wired into the telemetry pipeline (PromEx), so a rise
is visible on a dashboard and can drive an SLO alert.

## Scope Check
- One `:telemetry.execute` (or PromEx event) on the revoke-failure branch + its metric registration.
  Tiny, single concern. < 100 LOC.

## Wiring
- [x] Implementation only (observability). No user-facing surface.

## Technical Requirements
1. On the `Guardian.revoke` failure branch in `auth_controller.ex` (~L167, the `error ->` case), emit a
   telemetry event (e.g. `[:stacks, :auth, :refresh, :revoke_failed]`) alongside the existing warning.
2. Register it as a PromEx metric (counter) so it appears on the auth dashboard.
3. (Optional) note a suggested SLO/alert threshold for a sustained rise.

## Reviewer Context
- The project uses PromEx for metrics; other auth events (login lockout, argon pool) already have
  telemetry — mirror that wiring, don't invent a new mechanism.
- Keep the existing `Logger.warning` (the log has the `inspect(error)` detail; the metric is the
  aggregate signal).

## Test Audit
_Compact — telemetry emission. Green when the event fires on revoke-failure and is registered._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 11 Op metrics | yes | ❌ a telemetry test asserts the `[:stacks, :auth, :refresh, :revoke_failed]` event fires when `Guardian.revoke` fails during refresh (attach a handler in the test, force the failure). |
| others | no | n/a — metrics-only |

## Definition of Done
- [ ] A telemetry event fires on the refresh revoke-failure branch; registered as a PromEx metric
- [ ] Validation path: an ExUnit telemetry test (attach handler, simulate revoke failure, assert the event) — the existing warning is retained
- [ ] `just verify` passes
- [ ] Test audit (embedded) is GREEN

## Dependencies
- #173 (the refresh endpoint / the revoke-failure branch).

## Agent Assignment
security-agent (or platform-agent for the PromEx wiring).

## Progress Notes
- 2026-07-10: Filed from #173's PE gate (P3). The revoke-failure path is currently log-only; add the
  aggregate metric so it's observable.
