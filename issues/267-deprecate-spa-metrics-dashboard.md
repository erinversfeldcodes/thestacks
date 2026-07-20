# Issue #267: Deprecate the SPA operational-metrics dashboard (superseded by Grafana)

## Summary
Remove the in-app `/admin/metrics` operational-metrics dashboard (US-5.1.1) — it is superseded by
the Grafana observability stack (ADR-021, #231/#236–240), was never fully wired (the SPA sends a
regular `access` token to endpoints that require `admin_session`, so no owner can load it), and
duplicates what Grafana + the public `/costs` page already show. Update docs + user stories to
reflect that the operational-metrics surface is Grafana.

## User Stories
US-5.1.1 (View the Metrics Dashboard) — **being deprecated / re-pointed at Grafana** by this issue.

## Goal
No dead/broken `/admin/metrics` route in the app; the ops-metrics surface is unambiguously the
Grafana dashboards; docs + user stories reflect this; #261/#262's decoder-contract + aggregation
learnings are preserved as prior art for the future PII/personal-insights dashboards (#268).

## Scope Check
- Controllers: removes 1 (MetricsController). Endpoints: removes 4. Net LOC negative (removal). No
  unrelated concerns. Does not split.

## Wiring
Removes router wiring — deletes the `/api/metrics*` routes + the SPA `/admin/metrics` route.

## Feature-Completeness Pre-Check
n/a — this REMOVES a partially-built, superseded surface (verified broken end-to-end: SPA sends
`access` token, `admin_auth_pipeline.ex:45` requires `admin_session`; no SPA break-glass login).

## Technical Requirements
**Remove (frontend):**
- `Route.AdminMetrics` (`Navigation/Route.elm`), `Page/Admin/Metrics.elm` (delete module),
  `frontend/tests/Page/Admin/MetricsProgramTest.elm`.
- All `AdminMetrics` wiring in `Main.elm` (import, `PageAdminMetrics` Model variant, route handler
  `:768`, `AdminMetricsMsg` + update handler, the "Admin" nav dropdown link to `/admin/metrics`).
- #261's metrics decoders/types in `Api.elm` (`getMetrics`/`getSourceHealth`/`getQualityTrends`/
  `getEnrichmentGaps` + `MetricsDashboard`/`SourceHealth`/`QualityTrends`/`EnrichmentGaps` types +
  their decoders) — now unused. Leave the `/costs` transparency decoders untouched.

**Remove (backend, Option A):**
- `/api/metrics*` routes (`core_web/router.ex:304-309`).
- `StacksWeb.MetricsController` + `metrics_controller_test.exs`.
- `Stacks.Admin.Metrics` context + `apps/core/test/stacks/admin/metrics_test.exs`.
- The `op.source_health_checks` seed rows #262 added (they only fed the removed source-health card).
  (Keep the `source_health_checks` table + `SourceHealthCheck` schema — real monitoring data.)

**Docs + user stories:**
- `docs/user-stories.md`, `docs/implementation-mapping.md` (US-5.1.1 block ~1109-1119), and
  `docs/technical-architecture.md`: mark US-5.1.1 "Operational Metrics" dashboard **superseded by
  the Grafana observability stack (ADR-021, #236–240)**; the metrics surface is Grafana, not an
  in-app page. Flag host-page dependents (partner-request cards, US-9.5.1 partner metrics) as needing
  a new home when built.

## Reviewer Context
- Grafana dashboards (`apps/core/priv/grafana/*.json`, validated by `e2e/tests/dashboards.spec.ts`
  "#236–240") are the retained ops-metrics surface — do NOT touch them.
- The public `/costs` page (CostController, US-5.1 cost transparency) is SEPARATE and stays.
- Elm compiler + `elm-review` (NoUnused) will catch any dangling ref — removal must leave both clean.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1 (API) / 10 (Elm) | yes | ✅ when the routes/page/controller/context + their tests are removed and `just verify` is green with no dangling refs (elm-review NoUnused clean, no dialyzer/credo warnings) |
| others | no | n/a — pure removal |

## Definition of Done
- [ ] `/admin/metrics` SPA route + `Page.Admin.Metrics` + Main.elm wiring removed; app compiles, elm-review clean — evidence: `elm-review` 0 errors + `elm make`
- [ ] `/api/metrics*` routes + `MetricsController` + `Stacks.Admin.Metrics` context + tests + #262 seed rows removed — evidence: diff + `just verify` green
- [ ] `#261` metrics decoders/types removed from `Api.elm`; `/costs` decoders untouched — evidence: diff
- [ ] Docs + user stories updated (US-5.1.1 superseded by Grafana; host-page dependents flagged) — evidence: diff
- [ ] `just verify` passes (no dangling refs, no unused-code warnings) — evidence: command→output
- [ ] Test audit GREEN — evidence: table

## Dependencies
Part of the #119 epic (lands on `feat/119-e2e`). Enables the #119 reshape (US-5.1 → Grafana surface).
Prior art preserved for #268 (future PII dashboards).

## Agent Assignment
elm-agent + elixir-agent

## Progress Notes
- 2026-07-20: Filed after #119's E2E authoring surfaced the SPA dashboard is broken end-to-end
  (admin_session token never obtained by the SPA) and the review found it superseded by Grafana.
  Owner chose to deprecate (Option A — remove the backend context too).
