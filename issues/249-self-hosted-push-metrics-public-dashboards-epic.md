# Issue #249 (EPIC): Self-hosted push-based metrics + public dashboards

## Summary
Rebuild the observability implementation so metrics actually flow and are publicly visible,
per ADR-021 (which amends ADR-019 §2/§5). Replace the never-working Fly-managed-Prometheus
scrape + SSO fly-metrics.net Grafana with: a self-hosted **VictoriaMetrics** store, **push**
(`remote_write`) ingestion, a self-hosted **anonymous public Grafana**, an `@allowlist`
(fail-closed) + per-metric `:public`/`:operator` **audience** privacy boundary, and a
**curation pass** enforcing "only measure what we display." Dissolves #248.

## User Stories
Epic #231 (radical transparency) — implementation rework. No new stories; makes the existing
transparency surface (#241/#235) actually have data and be public.

## Goal
`stacks_*` metrics are stored, real-time, and rendered on public + operator dashboards with no
SSO; the transparency page has data; every surviving metric earns a panel; PII stays
fail-closed; the core app keeps scale-to-zero and only one tiny VM machine is always-on.

## Why (grounding)
- #248: Fly-managed-Prometheus scrape has **never** ingested app metrics (scale-to-zero + 6PN
  scrape never auto-starts the target; verified live).
- Metric audit (49 families): **8 event-derivable, 36 runtime-only, 5 partial** → a
  Prometheus-class store is required; Postgres can't replace it.
- fly-metrics.net is SSO-only → can't be public and can't be provisioned from code.

## Decomposition (dependency order; each child ≤3 controllers / ≤2 endpoints / ~300 LOC)

1. **#250 Audience classification gate (no drops).** Under the ADR-021 §4 rule (public unless
   PII/de-anon), **all 49 current families are public** — nothing is dropped (display, don't
   delete). Build the fail-closed **classification gate**: a new metric defaults to *not-public*
   and must be explicitly promoted; the two non-public routes are per-user (#242 own-view) and
   admin break-glass (#138) — mechanism/route only, not built here. Output: all-current-public +
   the gate + a test proving a new metric isn't public until promoted. (No infra.)

2. **#251 `@whitelist` → `@allowlist` rename + fail-closed audience gate.** Rename the
   transparency attribute + API (`allowlist_keys/0`, `:not_allowlisted`) and wire the audience
   registry as the public/operator boundary. (Scoped to `transparency.ex` + its 2 consumers +
   tests; do NOT touch the unrelated "bounded whitelisted atom" comments elsewhere.)

3. **#252 VictoriaMetrics deploy.** `deploy/fly.victoriametrics.toml` (always-on tiny VM +
   persistent volume, 6PN-only, remote-write auth). Preview parity in `deploy-stack.sh`. Infra.

4. **#253 Push ingestion (`remote_write`).** App remote_writes to VM over 6PN while alive;
   retire the Fly `[metrics]` scrape reliance + `MetricsAuth` scrape bypass for ingestion.
   Verify samples land in VM after a deploy+drive.

5. **#254 Self-hosted public Grafana.** Fly app (or co-located), anonymous viewer,
   file-provisioned datasource (→ VM, `uid: prometheus`) + curated dashboards-as-code. Public
   URL. Retire PromEx Grafana-upload path + `GRAFANA_HOST`/`GRAFANA_AUTH_TOKEN` secrets.

6. **#255 Repoint transparency page (#241) to self-hosted VM.**
   `Stacks.Transparency.Prometheus` queries the self-hosted VM (same Prometheus HTTP wire) via
   `@allowlist`; durable marts unchanged. Public page shows the `:public` set.

7. **#256 Completeness gate + retire dead infra.** Repurpose `DashboardDriftTest` to enforce
   *measured ⊆ displayed* (every registered metric has a public panel; a future non-public metric
   must be routed to #242/break-glass or the build fails). Re-point the #232 dashboard-smoke at the
   self-hosted VM. Close/retire #248; remove Fly-managed-Prometheus + fly-metrics.net assumptions
   from docs. Update the runbook.

## Dashboard quality bar (acceptance — the human-friendliness standard)
The reference is `~/machine_learning_engineering_interview_detached/infra/grafana/operations.json`
("AVSA Operations"). Every dashboard shipped by this epic MUST meet that bar (extends the #233
self-explanatory-dashboard standard; `DashboardStandardTest` is extended to enforce the structural
items, and each must be verified rendering **live against real VM data** before merge):
1. **Row sections** with thematic names, each opening with a **"What this section measures"** text
   panel (plain-language intro to the section).
2. **Titles that teach how to read the panel** (carry the key caveat/interpretation in the title,
   e.g. "means are additive; p95s are not").
3. **Descriptions = diagnostic narratives** — what's normal, what a rise/fall means, what to do —
   not bare definitions. (≥40 chars is the floor, not the goal.)
4. **Correct units on every panel** (ms, percentunit, reqps, short…) so values are human-readable.
5. **Panel type matches the signal** — `stat` for current values, `timeseries` for trends,
   `state-timeline` for state history (e.g. circuit-breaker green/red).
6. **PromQL correct** — `histogram_quantile` for percentiles, `_sum/_count` for smooth means,
   sensible rate windows; dashboard refresh + datasource templated.

Decision (dashboards): **(a) keep the existing 6 JSONs as the starting spec and upgrade them to
this bar** (reuse the teaching descriptions; add rows/section-intros; fix units/types; validate
live). All are **public** dashboards (no operator tier). No metric is dropped, so no panels are
removed for curation — every registered metric keeps its panel.

## Dead-delivery removal (do first, part of #256 / a cleanup commit)
These are wired to the abandoned Fly-managed-Prometheus + fly-metrics.net path — deleted, not
adapted: the PromEx Grafana-**upload** path (`prom_ex.ex` grafana assign + `runtime.exs`
`GRAFANA_HOST`/`GRAFANA_AUTH_TOKEN` branch); the CI dashboard-smoke step + GitHub secrets
(`FLY_PROMETHEUS_ORG`, `FLY_PROMETHEUS_READ_TOKEN`, `GRAFANA_HOST`) as wired to Fly Prometheus;
the Fly `[metrics]` scrape reliance for ingestion. KEEP: telemetry emission + emission tests
(real data), `dashboard-smoke.sh` (re-pointed at VM), the dashboard JSONs (upgraded per above).

## Top risks
- **remote_write auth over 6PN** — VM's write endpoint must reject public callers but accept the
  app; don't recreate the MetricsAuth ambiguity (test it).
- **Audience fail-closed** — default *not-public*; a test must prove a newly-added metric is NOT
  public until explicitly promoted (the blog-engagement-PII scenario). All 49 current families
  are promoted to public (aggregate, non-PII, non-de-anon).
- **Always-on cost** — one tiny VM machine; keep it minimal (single binary, small volume);
  confirm core app stays `min_machines_running = 0`.
- **Public Grafana exposure** — anonymous viewer must be **read-only, no admin** (Grafana
  `GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer`, admin disabled). Since all current dashboards are public
  this is straightforward; the guard matters for when a future non-public metric exists.

## Completion requirement — automated rendering gate (non-negotiable)
The existing drift + label-validation tests are **structural only** — they prove panel↔metric
consistency but never evaluate a query, so they stay green while every panel is blank (the false
confidence this epic exists to kill). **Completion of this epic REQUIRES an automated rendering
gate** that actually evaluates every dashboard panel's PromQL against a live store with data and
asserts non-empty — no "eyeball it" step is acceptable. Two layers:
1. **Render-correctness (`just render-gate`, CI with the docker stack):** synthesize well-formed
   data for every panel (metric + label matchers + histogram `_bucket`/`_sum`/`_count` structure +
   ≥2 timepoints for `rate()`), import to the local VM, evaluate EVERY panel query, assert
   non-empty. Fails the build on any blank panel or malformed PromQL. Deterministic, no app needed.
2. **Emission fidelity:** the app-side telemetry tests + label-validation prove the app emits each
   family with the registered tags; the preview `dashboard-smoke` (re-pointed at the deployed VM,
   post-E2E) proves real emission renders end-to-end. Together: measured ⊆ displayed AND displayed
   renders.

## Verification
- **`just render-gate` green** — every panel renders non-empty against the local VM (the gate above).
- After #252/#253: query the self-hosted VM directly — `stacks_*` samples present post-drive.
- After #254: hit the public Grafana URL unauthenticated → dashboards render with data.
- After #255: transparency page shows live values from VM.
- #256: `DashboardDriftTest` green (measured ⊆ displayed); dashboard-smoke green against VM.
- `just run just verify` before each child's review.

## Dependencies
- ADR-021 (design lock). Supersedes the infra half of ADR-019 §2/§5 and #232; dissolves #248.

## Agent Assignment
- infra/deploy (#252/#254), elixir (#250/#251/#253/#255), platform/test (#256).
