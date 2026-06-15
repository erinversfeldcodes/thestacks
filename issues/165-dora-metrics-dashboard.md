# Issue #165: DORA delivery metrics — collection + admin dashboard

## Summary
Capture deployment events alongside the existing rollback audit rows, derive the four DORA metrics (deployment frequency, lead time for changes, change failure rate, mean time to recovery), and surface them as a "Delivery" section on the existing `Page.Admin.Metrics` curator's-desk dashboard.

## User Stories
N/A (platform / operator-facing).

## Goal
The owner can answer "are we shipping safely and quickly?" without leaving the admin dashboard. Each DORA metric reflects real audit-log data; no manual spreadsheet, no third-party SaaS.

## Background — what's already in place
Closed-out predecessor #136 explicitly deferred DORA: *"DORA metrics schema: explicitly deferred to a follow-up issue within this branch. Gate-observations JSON is forward-compatible with any schema we pick later."* (`plans/136-release-to-main-workflow-plan.md:79`). That follow-up is this issue.

Foundations to build on (do not re-do):
- `Stacks.Audit.log_rollback/1` already records rollbacks with `failed_sha`, `triggered_by`, `metadata.reason`, timestamp (`apps/core/lib/stacks/audit.ex:79`).
- `gate-observations.json` artifact (deploy-time + post-rollback) carries SLI breach state and timestamps.
- `Page.Admin.Metrics` (#061a, complete) provides the dashboard chrome — sparklines, section layout, owner-only access — into which a "Delivery" section slots without new top-level scaffolding.

## Scope Check
- Endpoints added: 1 (`GET /api/metrics/delivery`). ✅ ≤2.
- Controllers touched: 1 (`MetricsController`). ✅ ≤3.
- Production LOC: ~250 (audit helper, controller action, query module, Elm section). ✅ <300.
- Concerns: collection + read API + UI of *one* concept (delivery metrics) — not split.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.
- [ ] This issue is implementation only.

## Technical Requirements

### 1. Deploy-event collection
- New `Stacks.Audit.log_deploy/1` mirroring `log_rollback/1`. Fields:
  - `sha` (the SHA being deployed — **resource_id**)
  - `outcome` — `"succeeded"` | `"failed"` (the workflow's terminal status)
  - `merge_commit_at` — ISO-8601 timestamp of the merge commit on `main`. Lead time = `inserted_at - merge_commit_at`. Captured in the workflow via `git show -s --format=%cI ${{ github.sha }}`.
  - `triggered_by` — `"push"` | `"manual"` | `"retry"`
  - Metadata: workflow run URL, gate-observations summary (breached SLIs if any, otherwise empty list).
- Action `"system.deploy"` (parallels `"system.rollback"`).
- Telemetry: `[:stacks, :system, :deploy]` event with `count: 1` and the metadata as measurements/metadata split (mirroring `log_rollback`).
- Workflow integration: a new `record-deploy` step in `deploy-production.yml`, gated on the existing successful core-deploy step. Use the same `mix run -e '...'` shell pattern as the audit-log step in the rollback action; receives `DATABASE_URL` + `CLOAK_KEY` via `env:`.

### 2. Derivation queries — `Stacks.DeliveryMetrics`
Pure read module in `apps/core/lib/stacks/delivery_metrics.ex`. All four metrics computed from `audit_log` rows, parameterised by a window (default 30 days):
- `deployment_frequency/1` → count of `system.deploy` rows with `outcome=succeeded` in window, returned as `count` + bucketed-per-day series.
- `lead_time_for_changes/1` → median + p95 of `(inserted_at - metadata.merge_commit_at)` over `system.deploy` rows where `outcome=succeeded`. Returned in seconds.
- `change_failure_rate/1` → `count(system.rollback in window) / count(system.deploy where outcome=succeeded in window)`. 0..1 float.
- `mean_time_to_recover/1` → mean over rollback rows of `(rollback.inserted_at - failed_deploy.inserted_at)`, joining each rollback row to the prior `system.deploy` row by `metadata.failed_sha = resource_id`. Returned in seconds.

DORA bucketing reference values (display-only, surfaced as the "performer band" badge):
| Metric | Elite | High | Medium | Low |
|---|---|---|---|---|
| Deployment frequency | on-demand | weekly–monthly | monthly–6mo | <6mo |
| Lead time | <1 day | 1d–1w | 1w–1mo | >1mo |
| Change failure rate | 0–15% | 16–30% | 16–30% | 16–30% |
| MTTR | <1 hour | <1 day | <1 day | >1 week |

(Use the 2023 *State of DevOps* boundaries; document the source in a comment.)

### 3. Read API — `GET /api/metrics/delivery`
- New action on `CoreWeb.MetricsController`. Owner-only (reuse the existing `:owner_required` plug from #061a).
- Query string `?window=30d` (default), accepts `7d` / `30d` / `90d`.
- Response shape:
  ```json
  {
    "window_days": 30,
    "deployment_frequency": { "count": 12, "per_day": [{"date":"2026-04-30","count":1}, ...], "band": "high" },
    "lead_time_seconds": { "p50": 3600, "p95": 18000, "band": "elite" },
    "change_failure_rate": { "ratio": 0.083, "deploys": 12, "rollbacks": 1, "band": "elite" },
    "mttr_seconds": { "mean": 1800, "samples": 1, "band": "elite" }
  }
  ```
- ProtoJSON: define `DeliveryMetrics` message in `proto/stacks/admin/v1/delivery_metrics.proto`; regenerate Elm decoders via the standard codegen path.

### 4. Dashboard section — `Page.Admin.Metrics`
- New section *Delivery* added to the existing curator's-desk page. **Do not create a new page** — this is a new section in #061a's existing module.
- Four cards in a 2×2 grid, each card:
  - Big number (the headline value).
  - Performer-band pill (Elite / High / Medium / Low — colour-coded; muted gold for Elite, copper for Low; matches existing palette).
  - 30-day sparkline using the existing SVG sparkline component.
  - Tooltip on the band pill explains the DORA boundaries.
- Window selector pill row (7d / 30d / 90d) above the grid. Default 30d.
- Place section between *System health* and *Data quality trends* on the page.

## Reviewer Context
- The four DORA metrics are computed from audit rows, not from a separate metrics store. This means the source of truth is the same encrypted `audit_log` table the rest of the platform writes to — `Stacks.Vault` already handles metadata encryption, no new key handling.
- `metadata.merge_commit_at` is the *merge* commit timestamp on `main`, not the PR-author commit timestamp. DORA "lead time for changes" measures code → prod, and merge-to-main is the canonical gate moment in this repo (push-to-main triggers deploy).
- Change failure rate uses `succeeded` deploys (denominator) so failed deploys that never made it to prod don't dilute the ratio. Rollbacks of a failed-mid-deploy run still count as failures because the deploy attempt mutated prod state (image swap or partial migrate).
- `Page.Admin.Metrics` is owner-only via `:owner_required` plug, set up by #061a — do not introduce a separate auth path.

## Definition of Done
- [ ] `Stacks.Audit.log_deploy/1` implemented + unit tests covering succeeded/failed branches.
- [ ] `record-deploy` step added to `deploy-production.yml`, fires on successful core-deploy, asserted by `test/platform/deploy_production_workflow_test.sh`.
- [ ] `Stacks.DeliveryMetrics` module with property-based tests for the four derivations (synthetic audit rows in test fixtures).
- [ ] `GET /api/metrics/delivery` returns the documented shape; controller test covers owner-required gating + window parsing.
- [ ] `proto/stacks/admin/v1/delivery_metrics.proto` lints clean (`buf lint`); `mix proto.sync --check` passes.
- [ ] `Page.Admin.Metrics` Delivery section renders with real data; Elm test covers band-classification logic for boundary values.
- [ ] Manual verification: trigger one deploy + one forced rollback against staging, confirm both appear in dashboard within 30s.
- [ ] Tests written and passing.
- [ ] Standards compliance verified (`just verify` passes).

## Dependencies
- #061a (admin metrics dashboard chrome) — **complete**.
- #137 (rollback audit logging) — **complete on this branch**, merges as part of the release-to-main work.
- #131 (proto as single source of truth) — **complete**.

## Agent Assignment
Orchestrator (multi-language: Elixir audit + queries, workflow YAML, proto, Elm UI). Suggested specialists: elixir-agent (audit + queries + controller), platform-agent (workflow step), elm-agent (dashboard section).

## Progress Notes
[Updated by agents during execution.]
