# Grafana Dashboard Standard — "every panel teaches"

> Established 2026-07-15 (Issue #233, epic #231). Governs **ops** Grafana
> dashboards registered via `Core.PromEx.dashboards/0` and stored as
> dashboards-as-code under `apps/core/priv/grafana/`. Enforced by
> `Core.PromEx.DashboardStandardTest` — a new dashboard whose data panels lack a
> teaching description fails CI.

## Scope

This standard governs **operational** dashboards (the Fly/PromEx Grafana surface
used by operators to reason about the running system). It does **not** govern the
user-facing "curator's desk" statistics surface (#234/#235), which is product UX
and answers to `docs/agents/ux-reviewer.md` (the "curator's desk, not a Grafana
clone" bar), not this document.

## The rule — every data panel carries a teaching description

Every **data panel** (anything that renders a series — `timeseries`, `stat`,
`gauge`, `table`, `bargauge`, `heatmap`, …) MUST set a non-trivial `description`.
"Data panel" excludes Grafana **row** separators (`"type": "row"`), which are
layout only and are exempt.

The `description` must teach a first-time reader the panel in four elements:

1. **What it measures** — the quantity in plain language.
2. **How** — which Prometheus metric / expression backs it (e.g.
   `stacks_moderation_classification_count_total`), so a reader can trace the
   panel to the registered metric.
3. **What it means** — how to interpret a normal reading (units, expected shape).
4. **What a spike/drop indicates** — the operational signal: what a sudden rise,
   fall, or flatline should make the operator suspect or do.

A description shorter than ~40 characters cannot carry all four elements and is
treated as missing by the enforcement test.

### Example

> **Age-gate blocks (per 5m)** — Counts requests refused by the age gate
> (`stacks_age_gate_blocked_count_total`). Normally a low, steady trickle; a
> sustained spike suggests a mis-tagged catalogue item or an age-verification
> regression pushing legitimate users into the block path — cross-check with the
> age-verification success panel.

## Naming, datasource, tone

- **Datasource:** every panel target queries the shared datasource
  `datasource_id: "prometheus"` (set once in `Core.PromEx.dashboard_assigns/0`).
  Do not hard-code a per-panel datasource uid.
- **Titles** are short and noun-led ("Moderation funnel", "Vision request cost"),
  units in the panel `fieldConfig`, not the title.
- **Tone** is operational and neutral — describe the signal, not the incident.
- **Metrics must exist:** a panel may only query a metric family registered by the
  code (`Core.PromEx.Plugins.Stacks`). `Core.PromEx.DashboardDriftTest` enforces
  the two-way lock-step (no panel for a dead metric; no invisible registered
  metric) for the #228 moderation/age-gate families.

## Enforcement

- `Core.PromEx.DashboardStandardTest` iterates **every** entry returned by
  `Core.PromEx.dashboards/0`, loads each JSON from `priv/`, and asserts every
  non-row panel carries a description of adequate length. New dashboards
  (#236–#240) inherit the rule automatically — no test edit needed to cover them.
- `Core.PromEx.DashboardDriftTest` additionally guards metric ↔ panel drift for
  the first (#230) dashboard.

Adding a dashboard = add `{:core, "grafana/<name>.json"}` to
`Core.PromEx.dashboards/0`; the standard test then requires every data panel to
teach before CI passes.
