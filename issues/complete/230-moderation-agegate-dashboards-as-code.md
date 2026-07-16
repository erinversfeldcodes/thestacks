# Issue #230: Moderation + age-gate dashboards-as-code + validation

## Summary
The moderation-funnel and age-gate counters (#228) are emitted and exposed at `/internal/metrics`, but
**visualized nowhere** — `Core.PromEx.dashboards/0` returns `[]`. Add a Grafana dashboard **as code**
(checked into the repo, registered via PromEx `dashboards/0`) with **self-explanatory panels**, plus
tests that prove the dashboard stays in sync with the registered metrics and that the metrics are
actually exposed. No running Grafana is required to build or validate this — that's #232.

## User Stories
None directly — observability of US-4.1 (moderation) + US-4.2 (age-gate) §13 metrics. Child of epic
**#231**. Story-less does not mean test-less: every behaviour below has a validation path.

## Goal
A `moderation` (and `age_gate`) Grafana dashboard JSON lives in the repo, is registered via
`dashboards/0`, and every panel **teaches** (what it measures, how, what it means, what a spike/drop
indicates). A drift test fails if a panel references a metric name that isn't registered (or a
registered #228 metric has no panel); a live test proves `/internal/metrics` exposes those metrics
after the funnel runs. When a Grafana instance exists (#232), PromEx auto-uploads it.

## Scope Check
- More than 3 controllers? **No** — zero (dashboard JSON + `prom_ex.ex` `dashboards/0` + tests).
- More than 2 new endpoints? **No.**
- Exceeds ~300 LOC production? **No** — dashboard JSON (data, not logic) + a small `dashboards/0`
  wiring; the LOC is tests + JSON.
- Combines unrelated concerns? **No** — one concern: make the #228 metrics observable + validated.

## Wiring
- [x] User-facing when complete **at the ops layer** (renders on Grafana once #232 stands up the
      instance); this issue delivers the dashboard-as-code + validation, independent of the live instance.
- [ ] Implementation only.

## Feature-Completeness Pre-Check
n/a — no user story. The feature being built (a dashboard) does not exist today
(`dashboards/0 == []`), so this is build-in-scope, not a validation issue. Its own validation paths
are the drift test + the live-exposure test below.

## Technical Requirements

### 1. Dashboard as code
- Author a Grafana dashboard JSON (e.g. `apps/core/priv/grafana/moderation_funnel.json`, and an
  `age_gate.json` or a combined dashboard) with panels for the #228 metrics:
  - **Moderation funnel:** classification outcomes (`book`/`not_a_book`/`ambiguous`), ISBN
    resolution (`resolved`/`isbn_not_found`), tiering (`public`/`age_gated`), compound-expansion —
    ideally a funnel/stat + a rate-over-time timeseries.
  - **Age gate:** enforce `blocked` vs `passed`, verification `success` vs `invalid`.
- Register it via `Core.PromEx.dashboards/0` (currently `[]`) using the `{:core, "path.json"}` form so
  PromEx uploads it when a Grafana instance is configured (#232). Use the existing `datasource_id:
  "prometheus"` from `dashboard_assigns/0`.

### 2. Every panel teaches (the #233 standard, applied here first)
- Each panel carries a **description** (Grafana panel `description` field, rendered as an info tooltip)
  covering: *what it measures · how it's measured (which `:telemetry` event / metric) · what it means ·
  what a spike or drop indicates* (e.g. "`isbn_not_found` rate climbing → resolution/OCR regression;
  investigate Open Library/Google Books or the vision extract step").

### 3. Drift test (dashboard ↔ registered metrics)
- A test that parses the dashboard JSON, extracts the Prometheus metric names its panels query, and
  asserts **each is a metric family registered by `Core.PromEx.Plugins.Stacks`** (grep/introspect the
  registered names), AND that **every #228-registered moderation/age-gate metric has at least one
  panel**. So renaming a metric (or adding one without a panel) fails CI. This is the "no invisible
  metric / no dangling panel" guard.

### 4. Live exposure test
- A test (or a scripted check runnable against a local stack) that exercises the funnel + age-gate
  paths and asserts `GET /internal/metrics` then contains the expected `stacks_moderation_*` /
  `stacks_age_gate_*` / `stacks_age_verification_*` families with non-zero samples — proving the
  registered→scrapeable path end-to-end (not just that firing tests pass).

## Reviewer Context
- `/internal/metrics` is authed by `StacksWeb.Plugs.MetricsAuth` (token `METRICS_SCRAPE_TOKEN`) — the
  live-exposure test must present the token (see `user_settings`/metrics tests for the pattern).
- The exact registered metric names come from `#228`'s `Core.PromEx.Plugins.Stacks` `counter/2`
  entries (`[:stacks, :moderation, :classification, :count, :total]` → `stacks_moderation_classification_count_total`,
  etc.) — the drift test must read them from the plugin, not hard-code, so it can't drift.
- Dashboards are **as code**; do not require a running Grafana to test. Upload to a live Grafana is
  #232's job.
- UX note (`ux-reviewer.md:62`): ops Grafana is functional; the *bespoke* "curator's desk"
  presentation is the user-facing surface (#234/#235), not this issue.

## Test Audit

_Compact format — an observability/harness issue (no US surface). The load-bearing layers are the
**drift test** (dashboard ↔ registered metrics) and the **live-exposure test** (metrics scrapeable).
Verified 2026-07-15: `dashboards/0 == []` today (no dashboard exists)._

Legend: ✅ real · ⚠️ shallow · ❌ missing · n/a (reason)

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Observability — dashboard exists + registered | **yes** | ❌ `Core.PromEx.dashboards/0` returns `[]`; no dashboard JSON in repo. Needed: dashboard JSON + `dashboards/0` registration. (→ ✅) |
| Observability — drift (dashboard ↔ registered metrics) | **yes** | ❌ no test that panels reference only-registered metrics and that every #228 metric has a panel. (→ ✅) |
| Observability — live exposure | **yes** | ❌ no test that `/internal/metrics` exposes the #228 families with samples after exercising the funnel (firing tests prove emit, not scrape-exposure). (→ ✅) |
| Panel-teaches (self-explanatory) | **yes** | ❌ n/a today (no panels). Needed: every panel has a `description`. (→ ✅ + #233 standard) |
| 1–13 (app/US layers) | no | n/a — this issue adds a dashboard + its validation, not app behaviour; the underlying metrics are already firing-tested in #228 (`moderation_telemetry_test.exs`, `age_gate_telemetry_test.exs`). |

### Punch list (baseline)
| # | What's needed | Where |
|--:|---------------|-------|
| 1 | Dashboard JSON (funnel + age-gate panels, each with a teaching `description`) + register via `dashboards/0`. | `apps/core/priv/grafana/*.json`, `apps/core/lib/core/prom_ex.ex` |
| 2 | Drift test: panels reference only registered metrics; every #228 metric has a panel. | new `apps/core/test/core/prom_ex/dashboard_drift_test.exs` |
| 3 | Live-exposure test: exercise funnel → `/internal/metrics` contains the families with samples (with `METRICS_SCRAPE_TOKEN`). | new test (or extend `metrics_endpoint_test.exs`) |

Verdict: **baseline — 3 punch items (dashboard-as-code, drift test, live-exposure test).** Done when all three ✅. Validated WITHOUT a running Grafana; live rendering is #232.

## Definition of Done
- [ ] Moderation + age-gate Grafana dashboard JSON in the repo, registered via `Core.PromEx.dashboards/0`.
- [ ] Every panel has a teaching `description` (what/how/what-it-means/what-a-change-indicates).
- [ ] Drift test: panels reference only registered metric families AND every #228 moderation/age-gate metric has a panel (fails on rename or missing panel).
- [ ] Live-exposure test: after exercising the funnel + age-gate, `/internal/metrics` exposes the `stacks_moderation_*` / `stacks_age_gate_*` / `stacks_age_verification_*` families with samples.
- [ ] `just verify` passes.
- [ ] Test audit (above) GREEN.
- [ ] Meets the Completion Bar — the validation paths (drift + live-exposure) are real tests, not assumptions; live Grafana rendering tracked in #232.

## Dependencies
Depends on **#228** (merged — the registered metrics). Independent of #232 (validated without a live
Grafana). Integration branch: `feat/118-e2e` (merges into the combined #118+#231 PR).

## Agent Assignment
elixir-agent (dashboard JSON + `dashboards/0` + tests). Reviewer: elixir-reviewer + platform-reviewer
(observability wiring).
