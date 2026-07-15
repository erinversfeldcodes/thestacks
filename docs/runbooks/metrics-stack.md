# Runbook: Metrics Stack — Fly managed Prometheus + Grafana

**Severity:** P3 (observability — no user-facing impact)
**Owner:** Platform operator
**Last reviewed:** 2026-07-15

---

## Overview

The app exposes Prometheus text at `/internal/metrics` (PromEx, `Core.PromEx`).
Fly's **managed Prometheus** (bundled, $0, persists across deploys) scrapes it and
stores the series independently of the app machines. The dashboards-as-code in
`Core.PromEx.dashboards/0` (JSON under `apps/core/priv/grafana/`) render against
Fly's Grafana (fly-metrics.net).

### How the scrape is wired (Issue #232)

- `deploy/fly.core.toml` has a `[metrics]` block (`port = 4000`,
  `path = "/internal/metrics"`). Fly's Prometheus scrapes each machine
  **directly over the private 6PN network** — it never traverses fly-proxy.
- `/internal/metrics` is normally gated by `StacksWeb.Plugs.MetricsAuth`
  (bearer `METRICS_SCRAPE_TOKEN`). The scrape can't present a bearer, so the plug
  has a **scoped bypass**: a request is allowed without a token **iff** it has a
  `fdaa::/16` remote_ip **and** carries **no** `fly-client-ip` header (which
  fly-proxy stamps on every public-edge request). Public callers always have
  `fly-client-ip`, so the public path still requires the bearer. See the plug's
  `@moduledoc`.

### Grafana upload

- If `GRAFANA_HOST` + `GRAFANA_AUTH_TOKEN` are set (Fly secrets pointing at the
  org's fly-metrics.net Grafana), PromEx uploads the dashboards at boot
  (`config/runtime.exs`). If unset, upload is disabled (a no-op — boot is never
  broken) and dashboards are imported by hand (below).

---

## Deploy-time smoke check (live validation)

Config/plumbing is covered by unit tests locally; the **live** scrape/render is
DEPLOY-TIME only — do not fake it. After a preview/prod deploy:

1. **Fly is scraping.** Confirm the `[metrics]` target is up:
   ```
   fly metrics list -a thestacks-core     # or the Fly dashboard → Metrics
   ```
   Then query Fly's Prometheus (fly-metrics.net) for a known family, e.g.
   `stacks_moderation_classification_count_total` — a non-empty series means the
   scrape is landing.

2. **Dashboards resolve their panels.** Open the moderation/age-gate dashboard in
   Grafana (fly-metrics.net) and confirm panels render data (not "No data").

3. **Public path is still locked.** From outside 6PN, `GET https://<host>/internal/metrics`
   with no bearer MUST return `401`; with the bearer it returns the metrics text.

If step 1 fails: check the `[metrics]` block port/path matches the app listener
(4000 / `/internal/metrics`) and that the machine is healthy. If step 3 returns
200 without a bearer, STOP — the bypass is mis-scoped and metrics are public;
revert and re-check `MetricsAuth`.

---

## Manual dashboard import (if Grafana secrets are unset)

1. In fly-metrics.net Grafana → Dashboards → Import.
2. Paste the JSON from `apps/core/priv/grafana/<name>.json`.
3. Select the `prometheus` datasource when prompted (panels set
   `datasource_id: "prometheus"`).
