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
- [ ] Real p95 measured for the `bookshelves` route group against a deployed preview — evidence: captured measurement (value + date + conditions)
- [ ] `bookshelves_p95_ms` SLI added with a threshold justified against that measurement — evidence: diff + the margin rationale
- [ ] **Proving gate:** the gate reads a **real** `bookshelves_p95_ms` value from the metrics store on a real run — not a synthetic series, not "the tuple exists" — evidence: gate output showing the observed value
- [ ] Gate demonstrably **fails** when the threshold is breached — evidence: forced-failure run output
- [ ] `#112`'s Layer-11/12 `n/a — covered by SLO gate` rationale is now truthful for this route group — evidence: note in #112's audit
- [ ] `just verify` passes — evidence: command → output

## Dependencies
- A deployed preview to measure against
- Should be measured **after** #112 punch #3 if that changes the placements query shape

## Agent Assignment
`platform-agent`. Reviewer: `platform-reviewer`.

## Progress Notes
[Updated by agents during execution.]
