# ADR 021: Self-hosted, push-based metrics store (VictoriaMetrics) + public Grafana

**Status:** Accepted
**Date:** 2026-07-16
**Deciders:** Platform owner
**Technical area:** Observability, metrics ingestion/storage, transparency/privacy
**Amends:** ADR-019 §2 (Data architecture) and §5 (ops dashboards shown). The *product*
decisions of ADR-019 stand unchanged — public transparency, "every metric earns a panel,"
"ops dashboards shown not hidden." This ADR replaces only the **implementation**: where
metrics are stored, how they get there, and how they are visualised.
**Supersedes (infra only):** the Fly-managed-Prometheus + fly-metrics.net approach of #232;
dissolves the root cause behind #248.

---

## Context

Two findings forced a rethink of ADR-019's *implementation* (not its intent):

1. **The Fly-managed-Prometheus scrape has never ingested a single app metric** — prod or
   preview, since launch (Issue #248). Root cause is structural: the core app runs
   `min_machines_running = 0` (scale-to-zero), and Fly's managed Prometheus scrapes the
   machine **directly over 6PN, bypassing fly-proxy**, so it never auto-starts the target —
   `up=0` essentially always. A 3-min continuous-warm live-drive still produced no successful
   scrape. Scraping a scale-to-zero app is the wrong model.

2. **An audit of all 49 registered `stacks_*` families** showed only **8 are derivable from
   `event_log`**; **36 are genuinely runtime-only** — latency distributions (`repo_query`,
   `router_dispatch`, GDPR job durations), a gauge (`fuse_state`), and in-process counters
   (login failures, rate-limit rejections, the moderation funnel, MFA, read-path counts) —
   and 5 are partial. You cannot COUNT a p95 latency out of a table. So a Postgres/`event_log`
   store cannot replace a Prometheus-class TSDB; the tool choice was never the mistake.

3. **fly-metrics.net Grafana is SSO-only** — no service accounts, no mintable API tokens (so
   it can't be provisioned from code) and no anonymous access (so it can't be the *public*
   surface ADR-019 requires). It fails the transparency requirement by construction.

## Decision

### 1. Store — self-hosted VictoriaMetrics
One **always-on, tiny** VictoriaMetrics single-binary on its own Fly app
(`deploy/fly.victoriametrics.toml`, `min_machines_running = 1`, small persistent volume).
This is the only always-on component; **the core app keeps scale-to-zero**. Reachable on
6PN only; remote-write endpoint auth-guarded.

### 2. Ingestion — push (`remote_write`), never scrape
The app **pushes** metrics to VictoriaMetrics via Prometheus `remote_write` while it is alive
(PromEx/`:telemetry_metrics_prometheus` → periodic remote_write). Push is the correct model
for a scale-to-zero app: it emits when running and simply doesn't when asleep — no dependence
on an external scraper reaching a stopped machine. The Fly `[metrics]` scrape block and its
`MetricsAuth` 6PN bypass are retired for ingestion purposes.

### 3. Visualisation — self-hosted, anonymous **public** Grafana
A self-hosted Grafana (own Fly app or co-located with VM), **anonymous viewer access enabled**
(`GF_AUTH_ANONYMOUS_ENABLED`), **file-provisioned** datasource (→ VictoriaMetrics, `uid:
prometheus` to match the existing dashboard JSON) and dashboards-as-code from
`apps/core/priv/grafana/*.json`. This IS the "ops dashboards shown, not hidden" public surface
of ADR-019 §5 — no login, no SSO, no API token. Retire the PromEx Grafana-upload path and the
`GRAFANA_HOST`/`GRAFANA_AUTH_TOKEN` fly-metrics.net secrets.

### 4. Privacy boundary — `@allowlist` (fail-closed), three audiences
Rename the transparency `@whitelist` → **`@allowlist`** (allow-semantics, fail-closed) and its
API (`allowlist_keys/0`, `:not_allowlisted`). A metric is public **iff** it is on the
`@allowlist`; the default is **not-public**, so a new metric never leaks until it is explicitly
vetted and promoted (the posture we want precisely because PII metrics like blog-engagement are
coming).

**Gating rule: an operational metric is public unless it contains PII or can be de-anonymised.**
"Might reveal security posture" is NOT a reason to withhold. There are three audiences, only one
of which is a routine dashboard:
- **Everyone (public)** — every aggregate, non-PII, non-de-anonymisable metric. This is the bulk;
  **all 49 current families qualify** (each is keyed only on bounded whitelisted atoms — no
  user-id/handle/IP/email/free-text). Rendered on the public transparency page + anonymous public
  Grafana.
- **The producing user (own-only)** — per-user/personal metrics shown only to that user. This is
  the **#242** personal-inference surface (ADR-019 §3a): a separate per-user axis, NOT a dashboard
  tier.
- **Admin — break-glass only** — NOT a standing ops dashboard. Rare, explicit, logged elevated
  access (align with the **#138** break-glass mechanism), for the narrow future case of an
  aggregate-but-de-anon-risky metric that is neither public nor per-user. Not built in this epic —
  a classification value + route only.

There is no routine "operator dashboard." The public dashboard is the operator dashboard
(ADR-019 §5: ops dashboards are shown, not hidden).

### 5. Transparency page (#241) reads the self-hosted VM
`Stacks.Transparency.Prometheus` queries the **self-hosted VictoriaMetrics** (Prometheus HTTP
API — same wire protocol) through the `@allowlist`, plus durable dbt marts for totals/ratios
(ADR-019 §2 durable half, unchanged).

### 6. Curate first — "only measure what we display"
Before wiring, apply ADR-019 §6 governance: **nothing is dropped** — every metric that is worth
measuring earns a home on a dashboard (the escape valve from "measured ⊆ displayed" is *display*,
not delete; a metric is dropped only if it is a genuine duplicate of another series). Under the §4
gating rule, **all 49 current families are public**. The drift test
(`DashboardDriftTest`/`DashboardStandardTest`) is repurposed to enforce **measured ⊆ displayed**:
every registered metric must have a panel on the public dashboard (or, for a future PII/de-anon
metric, be routed to the #242 own-view / break-glass), or the build fails.

## Consequences

- **Dissolves #248** — no scrape of a sleeping app; push works with scale-to-zero.
- **One small always-on machine** (VictoriaMetrics; Grafana can share or be a second tiny app).
  Core app stays scale-to-zero. This is the true, minimal cost of having runtime metrics at all.
- **Public dashboards with no SSO** — anonymous Grafana + the transparency page.
- **`@allowlist` stays the reviewed, fail-closed privacy gate**; default is not-public, and an
  operational metric is promoted to public unless it is PII / de-anonymisable (all 49 current
  families are public). No routine operator dashboard; admin access is break-glass only (#138).
- **Prometheus-class fidelity retained** (rates, histograms, gauges) — unlike a Postgres store.
- Retires: Fly-managed-Prometheus scrape reliance, fly-metrics.net secrets, PromEx Grafana-upload,
  the #232 smoke gate's Fly-Prometheus assumptions (re-pointed at the self-hosted VM).

## Alternatives considered
- **Postgres/`event_log` store:** rejected — only 8/49 families are event-derivable; 36 are
  runtime measurements with no durable event; would mean reimplementing a TSDB in SQL.
- **Grafana Cloud free tier:** rejected — trades a self-run machine for a third-party hosted
  dependency (the coupling we are shedding); free-tier public-share/retention limits.
- **Fix the Fly scrape (min_machines_running=1 on core):** rejected — ends core scale-to-zero
  for the whole web tier and still fights the scrape-a-sleeping-machine model; push is cleaner.
- **Keep fly-metrics.net for ops + separate public page:** rejected — violates "ops dashboards
  shown not hidden" and the un-automatable-token problem remains.
