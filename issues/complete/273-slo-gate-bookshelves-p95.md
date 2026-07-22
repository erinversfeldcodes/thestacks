# Issue #273: Add `bookshelves_p95_ms` SLI to the SLO Gate

## Summary
`scripts/check-slo-gate.sh` gates p95 latency for the `auth`, `catalogue` and `upload` route groups
only (`:643-645`). The `:bookshelves` route group — which serves every shelf browse — has **no p95
SLI**, so Issue #112's Layer-11/12 "n/a — covered by SLO gate" delegation is currently **unbacked**
for this endpoint. This issue adds the missing SLI with a **measured** threshold.

Spun out of #112 punch item #24 under scope-lock: #112 is a test-only issue, and this changes a
deploy-blocking production gate.

## User Stories
None directly. Backs the Layer-11/12 coverage delegation for US-1.2.1–US-1.2.5.

## Goal
Shelf-browsing latency regressions block a deploy the same way auth, catalogue and upload regressions
do — with a threshold derived from real traffic rather than guessed.

## Scope Check
- Does this issue touch more than 3 controllers? No — no controllers.
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No — one tuple plus a calibration record.
- Does this issue combine unrelated concerns? No.

## Wiring
Router wiring: implementation-only (CI/deploy gate). No user-facing surface.

## Feature-Completeness Pre-Check
n/a — no user stories; this is an observability/deploy-gate change. Per the "do not trust the
self-classification" rule: the signal it gates (bookshelves p95) **must** be observed arriving for
real — see the proving gate in the DoD. It is not waved through as infra.

## Technical Requirements
- The gate mechanism is generic: `check-slo-gate.sh:647` iterates the tuple list at `:643-645`.
  Adding `("bookshelves", <threshold>, "bookshelves_p95_ms")` is mechanically one line.
- The route group is **already tagged** — `apps/core/lib/stacks_web/plugs/route_group.ex:33`
  (path-prefix plug, installed at `core_web/endpoint.ex:60`, read into telemetry at
  `core_web/telemetry.ex:430-431`), asserted by `route_group_test.exs:81-83`. No tagging work needed.
- **Do not guess the threshold.** Follow the `upload_p95_ms` precedent documented in the comment block
  at `check-slo-gate.sh:625-632`: the threshold was set from a **measured** run, not invented. Take a
  real measurement against a deployed preview under representative load, record the observed p95, and
  set the threshold with a justified margin above it. Record the measurement in this issue.
- Arming a guessed threshold risks blocking unrelated deploys — that is precisely why this is not
  being done inside a test-only issue.

## Reviewer Context
- Shelf browsing is a **read-only** path with a bounded query shape, so its p95 should be well under
  the write-heavy `upload` group's. Do not copy upload's threshold.
- Related: #112 punch #3 flags a possible N+1 in the placements preload path. Note that the controller
  calls `Shelving.get_bookshelf_shelves/2` (`bookshelf_controller.ex:71`), **not**
  `get_bookshelf_books/2`. If #112's N+1 work changes the query shape, **re-measure** before arming
  this gate — calibrating against a shape that is about to change would bake in a stale threshold.

## Test Audit
Compact format — deploy-gate issue.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Operational metrics (L11) | yes | ❌ → ✅ — `bookshelves_p95_ms` present in the gate and evaluated on a real run |
| Performance (L12) | yes | ❌ → ✅ — threshold derived from a captured measurement, not a guess |
| E2E / gate behaviour | yes | ❌ → ✅ — gate demonstrably fails when p95 exceeds the threshold (forced or simulated) |
| 1–10, 13 | no | n/a — no API, auth, DB, event, job, external service, storage, cache, dbt or cost surface changed |

## Definition of Done
- [x] Real p95 measured for the `bookshelves` route group against a deployed preview — evidence: 2026-07-22, `stacks-core-pr-feat-e2e-112.fly.dev`, 100 authenticated requests across all five shelves (all HTTP 200), scraped from the exact gate histogram `stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="bookshelves"}` via `/internal/metrics`: **p95 ≤ 100 ms** (72/100 under 50 ms, 99/100 under 100 ms)
- [x] `bookshelves_p95_ms` SLI added with a threshold justified against that measurement — evidence: `scripts/check-slo-gate.sh` tuple `("bookshelves", 500, "bookshelves_p95_ms")` (commit `83d7d83e`); threshold 500 ms matches the other read groups (auth/catalogue), ~5× headroom over the measured p95; calibration recorded in the code comment above the tuple
- [x] **Proving gate:** the gate reads a **real** `bookshelves_p95_ms` value from the metrics store on a real run — evidence: computed from the real preview scrape, `value=100 threshold=500 breached=False` — the gate reads a real observed value, not a synthetic series or "the tuple exists"
- [x] Gate demonstrably **fails** when the threshold is breached — evidence: forced-failure demo against the same real buckets, `threshold=50 value=100 breached=True → gate FAILS` (vs `threshold=500 → passes`); the comparison fires in both directions on real data
- [x] `#112`'s Layer-11/12 `n/a — covered by SLO gate` rationale is now truthful for this route group — evidence: #112 Layer 11 cell updated to `✅ RESOLVED` citing this SLI + the calibrated measurement (commit `83d7d83e`)
- [x] `just verify` passes — evidence: `just run just verify` EXIT 0 on `feat/e2e-112` (2749 elixir / 940 elm / 233 dbt); the gate script change is bash+embedded-python, `bash -n` clean

## Dependencies
- A deployed preview to measure against
- Should be measured **after** #112 punch #3 if that changes the placements query shape

## Agent Assignment
`platform-agent`. Reviewer: `platform-reviewer`.

## Progress Notes

### 2026-07-22 — measured, armed, and the threshold decision (orchestrator)

**Measurement (the calibration #273 demanded — NOT a copied default).** Against a healthy deployed
preview (`stacks-core-pr-feat-e2e-112.fly.dev`), 100 authenticated requests across all five shelves,
all HTTP 200, scraped from the **exact gate histogram** the SLO gate reads
(`stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="bookshelves"}` via
`/internal/metrics`, token-authed): **server-side router-dispatch p95 ≤ 100 ms** — 72/100 under 50 ms,
99/100 under 100 ms, all 100 under 250 ms. Gate then read `value=100 threshold=500 breached=False` on
real data; forced-failure demo at `threshold=50` gave `breached=True` (comparison fires both ways).

**Why 500 ms — and an honest note on the tradeoff.** 500 ms is the project's **read-tier** threshold
(shared with `auth` and `catalogue`, also read paths). That it equals theirs is *tier placement*, not
a blind copy — bookshelves is a read path, and the measurement (p95 ≤ 100 ms) confirms it belongs in
that tier. The honest tradeoff the reviewer rightly flags: 500 ms is ~5× the measured p95, so this SLI
only fires on **gross** production degradation (a lost index → seq scan on a large table, an infra
fault), not a subtle one. That is deliberate and correct here, because **the subtle regression this
route is most exposed to — an N+1 reintroduction — is guarded far more tightly one layer down**:
`apps/core/test/stacks/shelving_query_test.exs` asserts query-count **equality across data sizes**,
which fails deterministically on any N+1 regardless of latency. The SLO gate is the coarse
production-latency backstop; the unit test is the precise N+1 guard. Arming conservatively (read-tier,
generous headroom) also follows the `upload_p95_ms` precedent of avoiding false-positive deploy blocks
from cold-start/load variance. **Follow-up worth tracking:** once a production p95 baseline and its
variance are observed, this can tighten toward ~250 ms (2.5× headroom) to catch subtler degradation —
noted here rather than guessed at now.
