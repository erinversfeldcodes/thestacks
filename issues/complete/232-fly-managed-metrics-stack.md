# Issue #232: Live metrics stack — Fly managed Prometheus + Grafana

## Summary
Make the dashboards actually render: wire Fly's **managed Prometheus** (bundled, $0, persists across
deploys) to scrape the app's metrics, and register the dashboards for upload to Fly's Grafana
(fly-metrics.net). Owner decision (2026-07-15): lowest-cost solution that persists across deployments.
Child of epic **#231**; part of the current PR.

## User Stories
None — observability infrastructure. Child of **#231**.

## Goal
Fly's Prometheus scrapes the app's metrics on every deploy and stores the series independently of app
machines (survives redeploys); the #230 (and later #236–#240) dashboards are available in Grafana.
Validated by a config/plumbing test locally + a deploy-time smoke check.

## Scope Check
- >3 controllers? No. >2 endpoints? No (may add ONE internal-only metrics listener/bypass). >300 LOC?
  No (fly.toml config + a metrics-exposure tweak + tests). Mixed concerns? No — metrics infra.

## Wiring
- [x] Deploy/infra — user-facing at the ops layer once live.

## Feature-Completeness Pre-Check
n/a — no user story. The app already exposes Prometheus text at `/internal/metrics` (PromEx); this wires
the scrape + store + Grafana.

## Technical Requirements

### 1. Fly metrics scrape (`deploy/fly.core.toml`)
- Add a `[metrics]` block pointing Fly's Prometheus at the app's metrics (port + path).
- **MetricsAuth wrinkle:** `/internal/metrics` is gated by `StacksWeb.Plugs.MetricsAuth`
  (`METRICS_SCRAPE_TOKEN`); Fly's scraper hits it over the private 6PN network and can't easily present
  the token. Resolve by exposing the Prometheus text on an **internal-only** path/port that is
  unauthenticated **only** on the private network (e.g. a `MetricsAuth` bypass when the request arrives
  on the Fly private interface / a dedicated internal listener) — never expose it unauthenticated on the
  public edge. Document the chosen approach.

### 2. Grafana dashboard upload
- Register the dashboards (already in `dashboards/0`) for upload to Fly's Grafana: PromEx `grafana:`
  config (host = fly-metrics.net org, auth token as a Fly secret) so PromEx uploads them at boot; OR
  document the manual/one-time import if API upload to fly-metrics isn't supported. `dashboard_assigns/0`
  already sets `datasource_id: "prometheus"`.

### 3. Validation
- **Local/CI:** a test that the `[metrics]` config is present + well-formed, and that the internal
  metrics path returns Prometheus text over the private-network path without the public auth (i.e. the
  bypass works as scoped, and the public path still 401s without the token).
- **Deploy-time:** a smoke check on the preview/prod deploy that Fly is scraping (metrics appear in
  Fly's Prometheus) and the dashboards resolve their panels. Record it in `deploy-stack.sh` or a runbook.

## Reviewer Context
- **Security:** the internal metrics bypass MUST be scoped to the private network only — a public
  unauthenticated `/internal/metrics` would leak operational data. Route through platform-reviewer.
- Fly's managed Prometheus retention is Fly-side (bounded, ~30 days) — fine for ops; durable
  user-facing stats read marts, not Prometheus (see #235).
- No new dependency/SaaS; uses the Fly org's bundled metrics + Grafana.

## Test Audit
_Compact — infra; local config/plumbing test + deploy-time smoke._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| `[metrics]` scrape config present + valid | yes | ❌ no `[metrics]` block in fly.core.toml. (→ ✅) |
| Private-network metrics exposure (auth bypass scoped correctly) | yes | ❌ (→ ✅ test: internal path OK, public path still 401) |
| Grafana upload config / documented import | yes | ❌ (→ ✅) |
| Deploy-time scrape smoke | yes | ❌ (→ ✅ deploy check + runbook) |
| 1–13 app layers | no | n/a — infra. |

Punch: (1) `[metrics]` config; (2) scoped internal exposure + test; (3) Grafana upload config; (4) deploy smoke.
Verdict: baseline — 4 punch items. Live scrape/render validation is deploy-time (documented).

## Definition of Done
- [ ] `[metrics]` block in `deploy/fly.core.toml` scraping the app's Prometheus text.
- [ ] Internal-only metrics exposure for Fly's scraper, scoped to the private network; public
      `/internal/metrics` still requires the token (test proves both).
- [ ] Grafana upload configured (PromEx `grafana:` + Fly secret) or a documented one-time import.
- [ ] Deploy-time scrape smoke check + a runbook note.
- [ ] `just verify` passes; config test GREEN.
- [ ] Meets the Completion Bar (live render confirmed on the preview deploy).

## Dependencies
#230 (dashboards to render). Part of the current #118+#231 PR. Live validation needs a preview/prod deploy.

## Agent Assignment
platform-agent (Fly config + metrics exposure) + elixir-agent (MetricsAuth bypass + test). Reviewer:
platform-reviewer (security of the internal exposure).
