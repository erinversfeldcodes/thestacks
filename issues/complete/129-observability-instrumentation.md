# Issue #129: Observability Instrumentation

## Summary
Add `:telemetry.execute` calls to key modules that currently lack instrumentation: vision client requests, fuse state changes, BudgetTracker cost recording, and Costs context. Then configure a metrics exporter (PromEx or `telemetry_metrics_prometheus_core`) so emitted events are scrapeable.

## User Stories
Cross-cutting — supports operational visibility for all stories involving vision API (US-1.1.1–1.1.3), budget tracking (US-1.1.1), and cost transparency (US-10.1.1).

## Goal
All significant runtime operations emit `:telemetry` events that are exported via a `/metrics` endpoint for Prometheus scraping. Grafana dashboards can visualise vision latency, fuse state, budget consumption, and cost accrual.

## Scope Check
- Does this issue touch more than 3 controllers? No (1 endpoint for metrics).
- Does this issue add more than 2 new endpoints? No (1: `/metrics`).
- Does this issue exceed ~300 lines of production code? Borderline — may need splitting into sub-issues.
- Does this issue combine unrelated concerns? Related — all observability.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete (`/metrics` endpoint).
- [ ] This issue is implementation only.

## Technical Requirements

### 1. Vision client request telemetry
Add to `Stacks.AI.Client.make_vision_request/2`:
```elixir
:telemetry.execute([:stacks, :vision, :request, :start], %{system_time: System.system_time()}, %{endpoint: endpoint})
# ... HTTP call ...
:telemetry.execute([:stacks, :vision, :request, :stop], %{duration: duration}, %{endpoint: endpoint, status: status})
```
Events: `[:stacks, :vision, :request, :start]`, `[:stacks, :vision, :request, :stop]`, `[:stacks, :vision, :request, :exception]`

### 2. Fuse telemetry wrapper
Wrap `:fuse.melt/1` and `:fuse.reset/1` calls in `AI.Client` to emit:
- `[:stacks, :fuse, :melt]` with `%{fuse_name: name}` — on every melt
- `[:stacks, :fuse, :blown]` with `%{fuse_name: name}` — when melt causes blow (check with `:fuse.ask/2` after melt)
- `[:stacks, :fuse, :reset]` with `%{fuse_name: name}` — on reset

### 3. BudgetTracker telemetry
Add to `handle_cast({:record_cost, ...})`:
```elixir
:telemetry.execute([:stacks, :budget, :cost_recorded], %{amount_cents: cost_cents}, %{provider: provider})
```
Add to `handle_call({:check_budget, ...})` when limit exceeded:
```elixir
:telemetry.execute([:stacks, :budget, :limit_exceeded], %{}, %{provider: provider, type: :daily | :monthly})
```

### 4. Costs context telemetry
Add to `Stacks.Costs.upsert_cost/1`:
```elixir
:telemetry.execute([:stacks, :costs, :recorded], %{amount_cents: amount}, %{category: category, service: service})
```

### 5. Metrics exporter
- Add `prom_ex` or `telemetry_metrics_prometheus_core` dependency
- Configure metric definitions for all custom events above plus existing Phoenix/Ecto/Oban events
- Expose `GET /metrics` endpoint (unauthenticated, internal-only via Fly private networking)
- Add to `CoreWeb.Telemetry` supervisor

## Reviewer Context
- `CoreWeb.Telemetry` already defines Phoenix and Ecto metric groups but has no consumers
- `:fuse` library has no built-in telemetry — this is a known limitation
- BudgetTracker is a GenServer; telemetry should be emitted inside `handle_cast`/`handle_call`, not in client API functions
- The `/metrics` endpoint must NOT be in the `:api` pipeline (no auth required, but should be restricted to internal network)

## Definition of Done
- [ ] Vision client emits `[:stacks, :vision, :request, :start/:stop/:exception]`
- [ ] Fuse wrapper emits `[:stacks, :fuse, :melt/:blown/:reset]`
- [ ] BudgetTracker emits `[:stacks, :budget, :cost_recorded/:limit_exceeded]`
- [ ] Costs context emits `[:stacks, :costs, :recorded]`
- [ ] `/metrics` endpoint returns Prometheus-format text
- [ ] Tests verify all new telemetry events fire correctly
- [ ] Suite 11 gap comments updated to reference this issue
- [ ] `just verify` passes

## Dependencies
None.

## Agent Assignment
elixir-agent

## Progress Notes
[Updated by agents during execution.]
