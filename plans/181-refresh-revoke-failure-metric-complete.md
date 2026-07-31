# Issue #181 — Complete

**Issue**: #181 — Metric on refresh revoke-failure (P3, follow-up from #173's PE gate)
**Branch**: `181-refresh-revoke-failure-metric` (off `feat/124-e2e-auth`)
**Completed**: 2026-07-10
**Agent**: elixir-agent · **Revision cycles**: 0

## What shipped
`AuthController.refresh/2`'s revoke-failure branch (`auth_controller.ex:179`) now emits
`:telemetry.execute([:stacks, :auth, :refresh, :revoke_failed], %{count: 1}, %{})` alongside the
retained `Logger.warning` — so the degraded case (old JWT not revoked, stays live until TTL, rotation
weakened) is counted and alertable instead of log-only. Registered as a PromEx counter in
`prom_ex/plugins/stacks.ex` → exports as `stacks_auth_refresh_revoke_failed_count_total`. Mint/return
behaviour unchanged; empty metadata (no PII/tags).

## How it was tested (honest, no production seam)
`Guardian.revoke("not-a-real-token")` returns `{:error, :not_found}` cleanly, so the controller test
calls `refresh/2` directly with `put_current_resource(user)` + `put_current_token("not-a-real-token")`
— driving the **real** revoke-failure branch (warning observably logged, 200 still minted from the
resource) while a telemetry handler asserts the event fires with `%{count: 1}`. A second test
(`prom_ex_custom_metrics_test.exs`) emits the event and asserts the series appears in scraped PromEx
output — proving the counter is registered/exported. RED before, GREEN after; refresh's 38 tests
unaffected.

## Gate record
- 2A-iv reception: DoD met; independently re-verified (emission + counter present, 41/0).
- 2B-i `just verify`: **exit 0** (full suite: elixir + elm + rust + python + dbt + lint).
- 2B-ii spec coverage: branch-emission + registration/export both covered.
- 2B-iia fresh-DB: **skip** (no migration). 2B-iii deploy/E2E: **skip** — observability change, no
  deployed-behaviour surface; the ExUnit telemetry test is the validation path.
- 2C elixir-reviewer: **APPROVE-WITH-NITS** — correct branch, clean wiring, honest non-vacuous test,
  zero PII. Only nit: pre-existing `Process.sleep(50)` ETS-propagation wait in the PromEx test (P2,
  matches the existing fuse-metric test pattern; accepted).
- 2F PE: skipped (trivial single-branch observability add).

## Files
- `apps/core/lib/stacks_web/controllers/auth_controller.ex` (emission)
- `apps/core/lib/core/prom_ex/plugins/stacks.ex` (counter)
- `apps/core/test/stacks_web/auth_controller_test.exs` (branch-emission test)
- `apps/core/test/core/prom_ex_custom_metrics_test.exs` (registration/export test)

## Follow-up noted (out of scope)
`logout/2` (`auth_controller.ex:100`) has a structurally identical, currently unmetered revoke-failure
branch. A symmetric `[:stacks, :auth, :logout, :revoke_failed]` counter would be a clean tiny
follow-up — not filed (low value; capture if logout-revoke alerting is ever wanted).

## Batch
Follow-up #1 of the #178–182 batch (order 181 → 178 → 182 → 179 → 180, per-issue gates). Next: **#178**.
