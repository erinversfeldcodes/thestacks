# Local observability stack

Run The Stacks' metrics pipeline on your laptop so you can **see the public dashboards
populate with real data** — the render path is identical to production
(VictoriaMetrics → Grafana), only the ingestion differs (local *scrapes*, prod *pushes*).

Part of **ADR-021** / **Epic #249** (self-hosted, push-based metrics + public dashboards).

## Run

```sh
# 1. Start Phoenix with metrics auth (token must match victoriametrics/scrape.yml).
METRICS_SCRAPE_TOKEN=local-dev-metrics-token just run mix phx.server

# 2. Bring up VictoriaMetrics + Grafana.
docker compose -f infra/local-observability/docker-compose.yml up

# 3. Open the PUBLIC view (anonymous — no login).
open http://localhost:3010
```

Then click around the app (register, upload, browse, block someone…) to emit metrics and
watch the panels fill in. VictoriaMetrics' own UI is at http://localhost:8428.

## What proves what

| Concern | Proven by |
|---|---|
| Grafana → store connectivity | datasource is file-provisioned (`uid: prometheus`), no token/SSO |
| Dashboards render for the public | Grafana **anonymous Viewer** — what an unauthed visitor sees |
| Metrics actually flow | VM scrapes `/internal/metrics`; panels go from "No data" → values |
| Dashboards meet the human bar | eyeball against `~/machine_learning_engineering_interview_detached/infra/grafana/operations.json` |

## Ingestion: local vs production

- **Local (here):** VictoriaMetrics *scrapes* `host.docker.internal:4000/internal/metrics`
  with a dev bearer token (`victoriametrics/scrape.yml`). Simplest way to see data.
- **Production (Epic #249 #252/#253):** the app *pushes* via `remote_write` — a `vmagent`
  co-located with the core app scrapes `localhost` and remote-writes to an always-on
  VictoriaMetrics. Push is what lets the **core app stay scale-to-zero** (it emits while
  awake; nothing to scrape while asleep). The Grafana render path is unchanged.

## Troubleshooting

- **All panels "No data":** is Phoenix running with `METRICS_SCRAPE_TOKEN=local-dev-metrics-token`?
  Check VM targets at http://localhost:8428/targets — the `thestacks-core-local` job should be `up`.
- **A `401` on the target:** the token in your shell doesn't match `victoriametrics/scrape.yml`.
- **Panels load but empty even with data:** the datasource `uid` must be `prometheus` (it is, in
  the provisioning file) to match the uid the dashboard JSON hard-codes.
- **`$app` variable empty:** the scrape labels the target `app: thestacks-core`; pick that value
  in the dashboard's App dropdown.
- **Grafana fills in but the app's own `/data-transparency` page is empty:** that page is not
  Grafana. `Stacks.Transparency` builds its own PromQL and substitutes `$app` with
  `FLY_APP_NAME || "thestacks-core"`, and `FLY_APP_NAME` is unset on a laptop — so the scrape
  label has to be `thestacks-core` for the page to match. It used to be `thestacks-local`, which
  Grafana coped with (its `$app` is `label_values(app)`) and the transparency page could not.
