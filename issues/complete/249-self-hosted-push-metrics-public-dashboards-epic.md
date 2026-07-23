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

## Decomposition (dependency order; each phase ≤3 controllers / ≤2 endpoints / ~300 LOC)

> These are **phases of this epic**, implemented directly — NOT separate issue files.
> `P1`–`P7` are phase labels for cross-reference, not tickets; don't go looking for
> `issues/25x-*.md`. Only **P1** is also broken out as its own ticket (**#250**),
> because it was scoped before the rest. All phases are ✅ done — see the commit log
> on `feat/wave2-observability`.


1. **P1 Audience classification gate (no drops).** Under the ADR-021 §4 rule (public unless
   PII/de-anon), **all 49 current families are public** — nothing is dropped (display, don't
   delete). Build the fail-closed **classification gate**: a new metric defaults to *not-public*
   and must be explicitly promoted; the two non-public routes are per-user (#242 own-view) and
   admin break-glass (#138) — mechanism/route only, not built here. Output: all-current-public +
   the gate + a test proving a new metric isn't public until promoted. (No infra.)

2. **P2 `@whitelist` → `@allowlist` rename + fail-closed audience gate.** Rename the
   transparency attribute + API (`allowlist_keys/0`, `:not_allowlisted`) and wire the audience
   registry as the public/operator boundary. (Scoped to `transparency.ex` + its 2 consumers +
   tests; do NOT touch the unrelated "bounded whitelisted atom" comments elsewhere.)

3. **P3 VictoriaMetrics deploy.** `deploy/fly.victoriametrics.toml` (tiny VM + volume, 6PN-only,
   remote-write auth). **Two lifecycles, one config:**
   - **Preview = EPHEMERAL.** A per-PR VM app created by `deploy-stack.sh` and **destroyed on
     teardown** with the rest of the preview (wire BOTH create and destroy — don't leak VMs). No
     always-on cost. Preview needs **no Grafana** — validation is `dashboard-smoke` querying the
     VM's Prometheus API directly (real-emission fidelity); no human views a preview dashboard.
   - **Prod = ALWAYS-ON.** `min_machines_running = 1`, provisioned once at prod cutover (the only
     standing cost). Core app stays scale-to-zero regardless.

4. **P4 Push ingestion — in-BEAM pusher (no vmagent/sidecar).** A
   `Core.PromEx.MetricsPusher` GenServer periodically POSTs PromEx's own text
   exposition (the same bytes `/internal/metrics` serves) to the VM's
   `/api/v1/import/prometheus` over 6PN (`http://<vm-app>.internal:8428`). VM accepts
   the Prometheus text format directly — no `remote_write` protobuf/snappy, no vmagent,
   no Dockerfile change. Runs inside the app, so it pushes while the app is alive and
   simply stops when it scales to zero (the scale-to-zero-friendly model that dissolves
   #248). Retire the Fly `[metrics]` scrape reliance + the `MetricsAuth` 6PN scrape
   bypass for ingestion. Verify samples land in VM after a deploy+drive.

5. **P5 Self-hosted public Grafana.** Fly app (or co-located), anonymous viewer,
   file-provisioned datasource (→ VM, `uid: prometheus`) + curated dashboards-as-code. Public
   URL. Retire PromEx Grafana-upload path + `GRAFANA_HOST`/`GRAFANA_AUTH_TOKEN` secrets.

6. **P6 Repoint transparency page (#241) to self-hosted VM.**
   `Stacks.Transparency.Prometheus` queries the self-hosted VM (same Prometheus HTTP wire) via
   `@allowlist`; durable marts unchanged. Public page shows the `:public` set.

7. **P7 Completeness gate + retire dead infra.** Repurpose `DashboardDriftTest` to enforce
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

## Dead-delivery removal (do first, part of P7 / a cleanup commit)
These are wired to the abandoned Fly-managed-Prometheus + fly-metrics.net path — deleted, not
adapted: the PromEx Grafana-**upload** path (`prom_ex.ex` grafana assign + `runtime.exs`
`GRAFANA_HOST`/`GRAFANA_AUTH_TOKEN` branch); the CI dashboard-smoke step + GitHub secrets
(`FLY_PROMETHEUS_ORG`, `FLY_PROMETHEUS_READ_TOKEN`, `GRAFANA_HOST`) as wired to Fly Prometheus;
the Fly `[metrics]` scrape reliance for ingestion. KEEP: telemetry emission + emission tests
(real data), `dashboard-smoke.sh` (re-pointed at VM), the dashboard JSONs (upgraded per above).

## Validated on Fly (standalone VM probe, 2026-07-16)
A throwaway `fly deploy` of `deploy/fly.victoriametrics.toml` proved the config **deploys and
VM boots/runs stably** on Fly (image + `[processes]` command + volume + `[[services]]`). Fixes
found and folded into the config: `processes = ["vm"]` is REQUIRED on the service when a named
process group exists; 256mb → 512mb. **Known lifecycle nuance for P3:** a 6PN-only app (no
public IP) is NOT managed by Fly's proxy, so `min_machines_running`/auto-start don't keep it up
on their own. Resolve in deploy-stack.sh by either allocating a **Flycast private IP**
(`fly ips allocate-v6 --private`) so the proxy enforces `min_machines_running`, or explicitly
`fly machine start` after deploy (as the core block already does for its machines).

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
- After P3/P4: query the self-hosted VM directly — `stacks_*` samples present post-drive.
- After P5: hit the public Grafana URL unauthenticated → dashboards render with data.
- After P6: transparency page shows live values from VM.
- P7: `DashboardDriftTest` green (measured ⊆ displayed); dashboard-smoke green against VM.
- `just run just verify` before each child's review.

## Dependencies
- ADR-021 (design lock). Supersedes the infra half of ADR-019 §2/§5 and #232; dissolves #248.

## Agent Assignment
- infra/deploy (P3/P5), elixir (P1/P2/P4/P6), platform/test (P7).

## Progress Notes
- **Verified absorbed / shipped, close-out audit 2026-07-23.** One artifact spot-checked per phase:
  - **P1 audience gate** — `Core.PromEx.MetricAudience` (`metric_audience.ex`), fail-closed, proven by
    `metric_audience_test.exs:33` (= issue #250, CLOSE-READY).
  - **P2 `@allowlist` rename** — `transparency.ex:77` `@allowlist` + `allowlist_keys/0:181`,
    `:not_allowlisted:200`.
  - **P3 VictoriaMetrics deploy** — `deploy/fly.victoriametrics.toml` present.
  - **P4 in-BEAM pusher** — `Core.PromEx.MetricsPusher` (`apps/core/lib/core/prom_ex/metrics_pusher.ex`).
  - **P5 self-hosted public Grafana** — `deploy/fly.grafana.toml` + `deploy/grafana/provisioning/datasources`.
  - **P6 transparency repoint** — `Stacks.Transparency.Prometheus` (`transparency/prometheus.ex` +
    `prometheus_client.ex`).
  - **P7 completeness gate** — `DashboardCompletenessTest` (`dashboard_completeness_test.exs`, global
    measured ⊆ displayed) + `just render-gate` (`scripts/dashboard-render-gate.sh`).
- **Six dashboards present** in `apps/core/priv/grafana/`: `auth_security`, `discovery`,
  `gdpr_data_rights`, `moderation_agegate`, `platform_ops`, `visibility_social`.
- **Far-end signal:** the automated live render-gate (`e2e/tests/dashboards.spec.ts`, gated on `GRAFANA_URL`)
  is **not reachable from this workspace** — no `GRAFANA_URL` in `.env`, so I could not evaluate every panel
  against the deployed VM from here. The `just render-gate` structural/synthetic gate exists but (per the
  completion-audit posture) proves PromQL well-formedness on synthesized data, not real emission. Strongest
  real-data evidence available here: the push pipeline is LIVE in prod since 2026-07-17 (project memory,
  ADR-021); the emission-gate + firing tests prove the app emits every family on the real path; child issues
  #239/#240/#250 are CLOSE-READY. **The one item I could not personally re-drive from this workspace is the
  end-to-end panel render against the deployed VM/Grafana** — cited via prod-live pipeline + CI's env-gated
  `dashboards.spec.ts`, not observed live in this audit.
