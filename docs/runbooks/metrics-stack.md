# Runbook: Metrics Stack — VictoriaMetrics push + self-hosted Grafana

**Severity:** P3 (observability — no user-facing impact)
**Owner:** Platform operator
**Last reviewed:** 2026-07-30

---

## Overview

The app exposes Prometheus text at `/internal/metrics` (PromEx, `Core.PromEx`),
but the pipeline is **push-based** (ADR-021): `Core.PromEx.MetricsPusher` POSTs
the same exposition to self-hosted VictoriaMetrics
(`deploy/fly.victoriametrics.toml`) via `STACKS_METRICS_PUSH_URL` every 15s
while the node is alive. Self-hosted Grafana (`deploy/fly.grafana.toml`) reads
VictoriaMetrics over 6PN; dashboards-as-code live in
`apps/core/priv/grafana/*.json`.

### Retired: the Fly managed-Prometheus scrape (Issues #232 / #248 / #323)

- `deploy/fly.core.toml` used to carry a `[metrics]` block (`port = 4000`,
  `path = "/internal/metrics"`) that made Fly's platform Prometheus poll each
  machine every 15s. That scrape **never ingested a single `stacks_*` series**
  (#248) and 401'd continuously against `StacksWeb.Plugs.MetricsAuth` — Fly's
  scraper cannot attach the `METRICS_SCRAPE_TOKEN` bearer (the `[metrics]`
  block has no header mechanism) and its requests did not satisfy the plug's
  6PN bypass. The block was removed in #323; if `fly logs` shows 15s-interval
  401s on `/internal/metrics` again, someone has re-added it.
- `/internal/metrics` remains gated by `StacksWeb.Plugs.MetricsAuth`
  (bearer `METRICS_SCRAPE_TOKEN`); its only legitimate external caller is the
  SLO gate (`scripts/check-slo-gate.sh`). The plug's narrow 6PN bypass (fdaa::
  remote_ip + no `fly-client-ip` header) is retained but no longer has a
  known caller. See the plug's `@moduledoc`.

### Grafana upload

- If `GRAFANA_HOST` + `GRAFANA_AUTH_TOKEN` are set (Fly secrets pointing at the
  org's fly-metrics.net Grafana), PromEx uploads the dashboards at boot
  (`config/runtime.exs`). If unset, upload is disabled (a no-op — boot is never
  broken) and dashboards are imported by hand (below).

---

## Deploy-time smoke check (live validation)

Config/plumbing is covered by unit tests locally; the **live** push/render is
DEPLOY-TIME only — do not fake it. After a preview/prod deploy:

1. **The push is landing.** Query VictoriaMetrics for a known family, e.g.
   ```
   curl -s "http://<vm-host>:8428/api/v1/query?query=stacks_moderation_classification_count_total"
   ```
   (over `fly proxy` / 6PN; prod VM is `thestacks-victoriametrics.internal`).
   A non-empty series means `Core.PromEx.MetricsPusher` is pushing. If empty,
   check the core app's logs for pusher errors and that
   `STACKS_METRICS_PUSH_URL` is set (unset ⇒ pusher is a no-op).

2. **Dashboards resolve their panels.** Open the self-hosted Grafana app and
   confirm panels render data (not "No data"). `dashboard-emission-gate.sh` and
   `e2e/tests/dashboards.spec.ts` cover this on preview.

3. **Public path is still locked.** From outside 6PN, `GET https://<host>/internal/metrics`
   with no bearer MUST return `401`; with the bearer it returns the metrics text.

If step 3 returns 200 without a bearer, STOP — the bypass is mis-scoped and
metrics are public; revert and re-check `MetricsAuth`.

---

## Manual dashboard import (if Grafana secrets are unset)

1. In fly-metrics.net Grafana → Dashboards → Import.
2. Paste the JSON from `apps/core/priv/grafana/<name>.json`.
3. Select the `prometheus` datasource when prompted (panels set
   `datasource_id: "prometheus"`).
