# Issue #248: Fly managed-Prometheus never ingests app metrics (dashboards + transparency page dataless)

## Summary
Our PromEx application metrics (`stacks_*`) have **never** been ingested by Fly's
managed Prometheus — in production *or* any preview. Every one of the 6 Grafana
dashboards (#233/#236–#240) and the public #241 transparency `/metrics` page is
therefore structurally dataless, and the Wave-2 dashboard-render smoke gate would
sit permanently red on preview for the same reason. Root cause is operational, not
code: the scrape target is down virtually always.

## User Stories
None — infra/observability platform. (But it silently invalidates the observable
half of #231 radical-transparency and every dashboard issue's live-exposure claim.)

## Goal
`stacks_*` series are present and non-zero in Fly managed-Prometheus for the core
app (prod + preview), so dashboards render and the transparency page has data — and
a test proves it stays that way.

## Evidence (read-only, via `https://api.fly.io/prometheus/personal/api/v1`)
Queried 2026-07-16 with a `fly tokens create readonly` macaroon:

| Check | Result |
|---|---|
| `stacks_*` series, any app, 18-month window (`start=2025-01-01`) | **0** |
| non-Fly metric names for `stacks-core-pr-feat-118-e2e` preview, ever | **0** |
| `max_over_time(up{app="thestacks-core"}[30d])` | **0** (both instances) |
| `max_over_time(scrape_samples_scraped{app="thestacks-core"}[30d])` | **0** |
| `count_over_time(up{app="thestacks-core"}[30d])` | **2–3 total scrapes / month** |
| metric prefixes present for `app="thestacks-core"` | only `fly_*` (821), `scrape_*` (12), `up` (2) |

The two scrape-target instance IDs Fly holds (`32872d64c90028`, `d894dddf019428`)
**match the current machines** (`fly status -a thestacks-core`) — targets are NOT
stale; they are `stopped`.

## Root cause
`deploy/fly.core.toml` sets `min_machines_running = 0` with `auto_stop_machines =
true`. The app auto-stops when idle. Fly's managed-Prometheus scrape reaches the
machine **directly over 6PN (never via fly-proxy)**, so — unlike a public request —
it does **not** trigger `auto_start_machines`. The scrape target is down (`up=0`)
essentially always, so no samples are ever collected. (The `[metrics]` block and the
`StacksWeb.Plugs.MetricsAuth` 6PN bypass are both correct; the machine just isn't
running when the scraper calls.)

Open sub-question (needs the live-drive below): even the 2–3 scrapes that *did* land
recorded `up=0`. That is consistent with catching the machine mid-stop, but could
also indicate a secondary endpoint/bind/auth failure that only shows when the machine
is demonstrably up. Confirm before settling the fix.

### Live-drive result (2026-07-16)
Kept `thestacks-core` continuously warm for ~3 min (health-pinged every 8s;
`fly checks list` showed `servicecheck-00-http-4000 = passing`, `{"status":"ok"}`
the whole time, so port 4000 was demonstrably serving). During and after that window:

- `max_over_time(up{app="thestacks-core"}[10m])` = **0** (stayed down)
- `max_over_time(scrape_samples_scraped[10m])` = **0**
- `query_range(scrape_samples_scraped, last 10m, step 30s)` = **0 datapoints** — Fly
  recorded no fresh scrape meta-metrics at all while the machine was up.
- `stacks_*` series = **0**.

So the failure is **not just sleep**: even a healthy, continuously-serving machine
produced no successful scrape. Prod also has **no secrets set at all** (`fly secrets
list` empty → no `METRICS_SCRAPE_TOKEN`), so `MetricsAuth`'s bearer path cannot
authorize; the scrape can only pass via the unauthenticated 6PN bypass. Leading
hypotheses, in order:
  1. **Fly's managed-Prometheus scraper source is not in `fdaa::/16`** (or arrives via
     a path that trips `proxied_from_public_edge?`), so `MetricsAuth` 401s every scrape
     → `up=0`. Fly's managed Prometheus cannot send a custom bearer, so if the 6PN
     bypass doesn't match its real scraper, the endpoint is unreachable to it forever.
  2. Fly isn't scheduling interval scrapes of the custom `[metrics]` target for this
     app/org at all (only a handful of attempts in 30 days) — a Fly-side discovery gap.
  3. Scrape-discovery + VictoriaMetrics ingestion lag longer than the 3-min window
     (least likely given the 30-day history, but not excluded by this test).

CANNOT be disambiguated purely read-only from outside 6PN. Next diagnostic step
(needs a deploy or interactive access, hence deferred to this issue's execution):
  - Run a longer **always-on soak** (`min_machines_running=1`, leave 20–30 min) and
    re-check `up`; if still 0 while healthy → it's the scrape response (hypothesis 1/2),
    not sleep/lag.
  - Probe the scrape response from a **second 6PN peer** (`fly ssh console` into a
    *different* app machine, `curl -6 http://<core-6pn-ip>:4000/internal/metrics`) to
    see the actual status code MetricsAuth returns to a real 6PN caller.
  - If 401: relax/repair the 6PN detection or set `METRICS_SCRAPE_TOKEN` + confirm
    whether Fly managed Prometheus can present it (it generally cannot — so the fix is
    almost certainly to make the 6PN bypass actually match Fly's scraper, or make
    `/internal/metrics` reachable to Fly's collector without a bearer).

## Technical Requirements
- The core app needs a **live scrape target whenever Fly scrapes**. Candidate fixes
  (decide after the live-drive):
  1. `min_machines_running = 1` on `deploy/fly.core.toml` — one always-on machine.
     Simplest; small always-on cost (512 MB shared-cpu-1x). Standard requirement for
     Prometheus scraping of an otherwise scale-to-zero app.
  2. A dedicated always-on process/machine that serves `/internal/metrics` while the
     web tier scales to zero (more moving parts; avoids keeping the full web machine warm).
  3. Push-based egress (PromEx `remote_write` / pushgateway) instead of relying on
     Fly scraping a scale-to-zero target — larger change, revisit only if 1/2 rejected.
- Preview parity: whatever keeps prod scrapable must also hold on the preview stack
  (`scripts/deploy-stack.sh`) or the #232 smoke gate never goes green.
- If the live-drive shows `up=1` but still 0 samples, additionally diagnose the 6PN
  scrape response (`fly ssh console` from a *second* 6PN peer, since localhost `::1`
  is not `fdaa::/16` and would 401 under MetricsAuth's bypass rule).

## Reviewer Context
- Fly managed-Prometheus scrapes over 6PN and does not auto-start machines — this is
  the crux; a reviewer expecting scrapes to wake the app will mis-read the fix.
- `MetricsAuth` allows the scrape only when `remote_ip ∈ fdaa::/16` AND no
  `fly-client-ip` header. A localhost curl inside the machine (`::1`) fails that gate.
- The dashboard-smoke gate (`scripts/dashboard-smoke.sh`) is the acceptance harness:
  once metrics flow on preview, it validates every panel query returns non-empty.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 11 operational metrics (scrape reaches Prometheus) | yes | ❌ needed — assert `up{app=…}==1` and ≥1 `stacks_*` sample after a preview deploy+drive (extend `scripts/dashboard-smoke.sh` connectivity step or a new check) |
| performance & usability | yes | ❌ needed — dashboards render non-empty (dashboard-smoke panel pass) |
| 1–10, 13 (app/US layers) | no | n/a — infra scrape plumbing, no app/user-story surface |

## Definition of Done
- [ ] Root cause confirmed live: machine warm ⇒ `up=1` and `stacks_*` samples appear
      in Fly Prometheus (or the secondary endpoint issue is identified and fixed).
- [ ] Chosen fix applied to `deploy/fly.core.toml` (+ preview parity in `deploy-stack.sh`).
- [ ] After a prod deploy, `stacks_*` series present and non-zero in Fly Prometheus;
      at least one dashboard panel renders data.
- [ ] `scripts/dashboard-smoke.sh` passes on a preview deploy (panels non-empty).
- [ ] Cost impact of an always-on machine acknowledged/accepted by the owner.
- [ ] `just verify` passes; standards compliance verified.

## Dependencies
- Interacts with #232 (dashboard-render smoke gate — this is what makes that gate
  meaningful) and #241 (transparency page — dataless until this lands).

## Agent Assignment
- infra/deploy (fly.toml + preview stack), with observability review.
