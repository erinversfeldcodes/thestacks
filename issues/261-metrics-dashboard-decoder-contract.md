# Issue #261: Metrics dashboard — fix the frontend decoder contract (render real data)

> **⛔ SUPERSEDED by #267 (2026-07-20).** This fix was built (merged `8e32a9a0`) and then **removed**
> when the SPA `/admin/metrics` dashboard was deprecated — it was discovered broken end-to-end (the
> SPA sends an `access` token; the endpoints require `admin_session`, and there is no break-glass UI)
> AND superseded by the Grafana observability stack (ADR-021/#236–240). The decoder-envelope +
> USD-formatting **pattern** is preserved as prior art for the future user-facing PII/personal-insights
> dashboards (**#268**). DoD below intentionally left unchecked — the deliverable was undone, not shipped.

## Summary
The admin metrics dashboard (`/admin/metrics`, `Page.Admin.Metrics`) never renders real data:
`StacksWeb.MetricsController` wraps every response in `%{data: …}`, but none of the four Elm
metrics decoders unwrap `data`. Unwrap `data` in all four decoders, relabel the cost ledger from
ZAR to USD (the values are USD cents, unconverted), and align the trend token so the neutral arrow
renders. Elm-only frontend display correctness for US-5.1.

## User Stories
- US-5.1 (metrics / transparency dashboard — admin view). This is the display-correctness slice;
  the live browser E2E for it is owned by #119.

## Goal
`/admin/metrics` shows real decoded values in all four sections — quality banner percentages,
source-health rows, enrichment-gap integers, and the cost ledger (labelled USD) — instead of
silent zeros/empties (getMetrics, getEnrichmentGaps) or hard decode `Failure` (getQualityTrends,
getSourceHealth). The neutral ("stable") trend arrow renders.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- More than 3 controllers? **No — 0 controllers touched (Elm-only; the backend envelope is already correct).**
- More than 2 new endpoints? **No — 0 new endpoints; the four `/api/metrics*` routes already exist.**
- Exceed ~300 lines of production code? **No — ~6 focused edits across two files (`Api.elm`, `Page/Admin/Metrics.elm`), well under 100 LOC.**
- Combine unrelated concerns? **No — every change is US-5.1 metrics-dashboard display correctness.**

**Verdict: clears all four splits. Size ~S.**

## Wiring
Implementation-only — the page and its four routes are already wired; this fixes the decode
contract only. The live end-to-end drive is owned by **#119**.

## Feature-Completeness Pre-Check
<!-- US-5.1's happy path (the admin dashboard UI, controller, routes, proto decoders, view) is BUILT;
     this issue fixes a decode-contract defect in a shipped feature. The four sections, cost table,
     GDPR card, and trend indicators all exist in `Page/Admin/Metrics.elm` and render for `Success`
     states — they just never reach `Success` (or reach it with defaulted zeros) because of the
     envelope mismatch. No story is being newly built or de-scoped here. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-5.1 admin metrics dashboard | routes → `MetricsController.index/quality_trends/source_health/enrichment_gaps` (`metrics_controller.ex:14-31`) → `Api.getMetrics/getQualityTrends/getSourceHealth/getEnrichmentGaps` (`Api.elm:2750/2824/2664/2867`) → `Page.Admin.Metrics` view sections (`Metrics.elm:180,210,257,288,330`) | ⬜ to verify (defect: sections show 0/empty or decode-`Failure`) | 🟡 | Fix the decode contract in-scope (this issue). Feature is built; the wire is broken, not the story. |

Verdict: 🟡 partial — the story is built end-to-end; the single missing hop is the decoder failing
to unwrap the `data` envelope. Resolved **in-scope** by this issue (defect fix, not a new build).

## Technical Requirements

All line numbers verified against the tree on `feat/119-e2e` (2026-07-20).

**Backend contract (source of truth — do not change):** `StacksWeb.MetricsController` wraps every
action in `%{data: …}` (`apps/core/lib/stacks_web/controllers/metrics_controller.ex:15,20,25,30`),
asserted by `metrics_controller_test.exs:45` (`assert %{"data" => data} = json_response(conn, 200)`).

### 1. Unwrap `data` in the four decoders (`frontend/src/Api.elm`)
- **`getMetrics`** — `Api.elm:2760`: `expect = Http.expectJson toMsg metricsDashboardDecoder`.
  Root decode + proto-lenient defaults (`fromProtoMetricsDashboard` uses `Maybe.withDefault 0.0`,
  `Api.elm:2713-2719`) → **silent** 0/0/0/empty. Wrap: `Decode.field "data" metricsDashboardDecoder`.
- **`getEnrichmentGaps`** — `Api.elm:2877`: `expect = Http.expectJson toMsg enrichmentGapsDecoder`.
  Root decode + lenient → **silent** 0/0/0. Wrap: `Decode.field "data" enrichmentGapsDecoder`.
- **`getQualityTrends`** — `Api.elm:2834`: `expect = Http.expectJson toMsg qualityTrendsDecoder`
  where `qualityTrendsDecoder` is a `Decode.list …` at root (`Api.elm:2818-2819`) → **hard `Failure`**
  (list decoder meets `{data: [...]}` object). Wrap: `Decode.field "data" qualityTrendsDecoder`.
- **`getSourceHealth`** — `Api.elm:2674`: `expect = Http.expectJson toMsg (Decode.field "sources" (Decode.list sourceHealthDecoder))`.
  Field `"sources"` is absent → **hard `Failure`**. Change `"sources"` → `"data"`.

### 2. Source-health decoder must decode plain strings (cross-cutting with #262)
`sourceHealthDecoder` (`Api.elm:2657-2659`) currently decodes via
`ProtoHealth.decodeSourceHealthCheck`, which expects **proto enums** for `source_type`/`status`.
**#262 will return source-health as plain strings** for `source_type`/`status` plus
`last_success_at`/`last_failure_at`. The target `SourceHealth` alias already uses `String` fields
(`Api.elm:2595-2602`: `{ name, sourceType (String), status (String), consecutiveFailures (Int),
lastSuccess (Maybe String), lastFailure (Maybe String) }`). Rework `sourceHealthDecoder` to decode
that plain-string JSON shape **directly** (drop `fromProtoSourceHealthCheck`/`sourceTypeToString`/
`healthStatusToString` for this path), matching the exact JSON keys #262 emits under `data`. See
Reviewer Context — this decoder and #262's controller land together on `feat/119-e2e`.

### 3. Cost ledger: relabel ZAR → USD (owner decision) (`frontend/src/Page/Admin/Metrics.elm`)
The cost values are **USD cents** with **no conversion** (`fromProtoCostItem` maps proto
`amountCents` straight into `amountZar`, `Api.elm:2739`), but the view renders them as Rands.
- Header `th [] [ text "Amount (ZAR)" ]` — `Metrics.elm:312` → `"Amount (USD)"`.
- `formatZar` — `Metrics.elm:391-400` renders `"R " ++ …` → replace with a `formatUsd` that renders
  `"$" ++ …` (dollars from cents); update the call site `viewCostRow` (`Metrics.elm:326`).
- (Supersedes #119 §1's "ZAR (R X.XX)" requirement — **#119's cost expectation changes to USD/`$`**.)

### 4. Trend token align (`frontend/src/Api.elm`)
`trendArrow` (`Metrics.elm:366-379`) matches `"up"/"down"/"stable"`, but the trend derivation emits
`"up"/"down"/"flat"` (`Api.elm:2793-2800` and the fallback `Api.elm:2810-2812`) → the neutral
`"→"` arrow never renders. Change the two `"flat"` literals in `fromProtoQualityTrendRows` to
`"stable"` to match the renderer.

## Reviewer Context
<!-- Non-obvious conventions the reviewer (contract-reviewer + elm-agent) needs. -->
- **Two different metrics pages — do not conflate.** `Page.Metrics` is the **public** transparency
  page at `/metrics` (no auth; already has `frontend/tests/Page/MetricsProgramTest.elm`).
  `Page.Admin.Metrics` is the **admin** dashboard at `/admin/metrics` — the buggy module here, with
  no happy-path program test.
- **The envelope contract is the whole bug.** Backend wraps `%{data: …}`
  (`metrics_controller.ex:14-31`, asserted by `metrics_controller_test.exs:45,75,93,111`); the Elm
  decoders decode at the wrong level. Two failure modes: proto-lenient defaults make
  `getMetrics`/`getEnrichmentGaps` fail **silently** (zeros), while `getQualityTrends` (list-at-root)
  and `getSourceHealth` (`field "sources"`) fail **hard** (`Http.BadBody`). A contract reviewer
  should confirm all four decoders now key off `data` and match the backend JSON exactly.
- **#262 cross-cut (source-health shape).** #262 delivers source-health as **plain strings** for
  `source_type`/`status` (not proto enums) plus `last_success_at`/`last_failure_at`. #261's
  `sourceHealthDecoder` rework (§2) must decode that exact shape under `data`. The two land together
  on `feat/119-e2e`; review them as a pair for key/shape agreement.

## Test Audit
<!-- Feature issue but Elm-only display correctness; the proving layer is Layer 10 (Elm state
     machine). Layers 2-9,12,13 are backend/infra and n/a to this frontend fix; Layer 1 (API
     contract) is partially covered by existing backend tests. -->

Legend: ✅ real coverage · ⚠️ shallow · ❌ missing · n/a not applicable (one-line reason).

| Layer | Applies? | Current verdict |
|-------|----------|-----------------|
| 1 — API calls / contract | yes | ⚠️ **partial.** `metrics_controller_test.exs:45,75,93,111` asserts the `%{data: …}` envelope + 401 auth on all four routes — proves the shape the Elm *must* match, but **nothing asserts the Elm decodes it**. (→ ✅ when the Elm program tests below land.) |
| 10 — Elm state machine | yes | ❌ **the proving layer, and it is empty.** `Page.Admin.Metrics` has **zero** program/render tests. The only test touching the module is `frontend/tests/Page/SessionExpiryPagesTest.elm:123-141` — a sad-path unit test on `update (DashboardReceived (Err unauthorized)) → SessionExpired`; no decoder-unwrap, no happy-path render. `frontend/tests/Page/MetricsProgramTest.elm` covers the **public** `Page.Metrics`, not this module. |
| 2 auth/middleware · 3 DB · 4 events · 5 Oban · 6 external svc · 7 storage · 8 cache · 9 dbt · 13 cost-tracking | no | n/a — this is a frontend decode/label fix; the admin-JWT/MFA guard (Layer 2) is already covered by `metrics_controller_test.exs` 401 tests and unchanged here. |
| 11 operational metrics · 12 perf/usability | no | n/a — no metric emission or perf surface in a decoder/label change. |

### Punch list (all Layer 10, one new suite: `frontend/tests/Page/Admin/MetricsProgramTest.elm`)
Model on the existing `frontend/tests/Page/MetricsProgramTest.elm` (elm-program-test with
`SimulatedEffect.Http`); feed **`data`-wrapped** JSON bodies matching the backend.

1. **getMetrics unwraps `data`** — respond `{"data": {…system_health/costs/gdpr…}}`; assert the
   Data Quality banner and GDPR card render **real** values (non-zero percentage / real pending
   count), proving it is not the silent-default 0.0%/0.
2. **getEnrichmentGaps unwraps `data`** — respond `{"data": {…}}`; assert the three gap cards render
   the real integer counts (not defaulted 0).
3. **getQualityTrends unwraps `data`** — respond `{"data": [ …≥2 rows… ]}`; assert it reaches
   `Success` (currently hard-`Failure`) and the trend arrows render.
4. **getSourceHealth unwraps `data`** — respond `{"data": [ {name, source_type (string),
   status (string), consecutive_failures, last_success_at, last_failure_at} ]}`; assert source-health
   rows render (name + type + status badge + failure count). Shape must match #262.
5. **Cost ledger renders USD** — assert the table header reads "Amount (USD)" and a cost row renders
   a `$`-prefixed value from cents (no "R ", no ZAR).
6. **Neutral trend renders** — with two equal-percentage trend rows, assert the `"stable"` token
   produces the `→` arrow (guards the token-align fix against regression).

**Validation path per behaviour:** elm program tests (items 1-6 above) prove decode + render at
Layer 10 — the correct tool for Elm view/state correctness. The **live browser drive** of
`/admin/metrics` on a real stack is **#119's** E2E, not duplicated here.

**Verdict: RED (baseline).** Layer 10 is empty for `Page.Admin.Metrics`; Layer 1 is backend-only.
Goes GREEN when the six program tests pass and each of the four sections renders decoded real data.

## Definition of Done
- [ ] All four decoders unwrap the `data` envelope (`getMetrics`, `getEnrichmentGaps`,
      `getQualityTrends`, `getSourceHealth`) — evidence: `Api.elm` diff + program tests items 1-4 GREEN.
- [ ] `getSourceHealth` decodes the #262 plain-string shape (`source_type`/`status` strings,
      `last_success_at`/`last_failure_at`) under `data` — evidence: program test item 4 + shape agreed
      with #262 in review.
- [ ] Cost ledger relabelled to USD — header "Amount (USD)" and `$`-formatted values from cents —
      evidence: program test item 5.
- [ ] Trend token aligned (`"flat"` → `"stable"`) so the neutral `→` arrow renders — evidence:
      program test item 6.
- [ ] **Each of the four sections renders decoded real data (not defaults, not error) in an elm
      program test** — evidence: `frontend/tests/Page/Admin/MetricsProgramTest.elm` items 1-4 asserting
      real values, elm-test run → output.
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for US-5.1** — the 🟡 hop (envelope unwrap) is
      built in-scope; sections observed rendering real data (program tests here; live drive tracked by
      #119) — evidence: program test run + note deferring live drive to #119.
- [ ] Every behaviour has a validation path — the six program tests (Layer 10); live browser E2E is
      `n/a here → #119` — evidence: this DoD + audit punch list.
- [ ] Tests written and passing (`elm-test`) — evidence: command → `N passed` output.
- [ ] Standards compliance verified (`just run just verify` — elm-format + elm-review clean) —
      evidence: command → output.
- [ ] **Test audit (embedded above) is GREEN** — Layer 10 ✅, Layer 1 ✅; 0 `❌`/`⚠️`. Regenerate as
      the final step — evidence: updated table.
- [ ] **`completion-audit` skill passed** on the integrated branch — evidence: cited run.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — decoder fix proven
      at Layer 10 locally before the #119 live drive; no dangling reviewer findings; audit regenerated —
      evidence: tokens above + contract-reviewer sign-off.

## Dependencies
- **None blocking.** Coordinates with **#262** on the source-health JSON shape (plain strings +
  `last_success_at`/`last_failure_at`); the two land together on `feat/119-e2e`.
- **Feeds #119** (metrics/RSS E2E) — #119's live `/admin/metrics` drive depends on this fix, and
  #119's cost expectation changes from ZAR to USD (§3).

## Agent Assignment
- **elm-agent** — the decoder + view-label changes and the new program-test suite.
- **contract-reviewer** — verify the four decoders match the backend `%{data: …}` envelope and the
  source-health shape agrees with #262.

## Progress Notes
- 2026-07-20: Scoped from #119's feature-completeness pre-check. All six findings confirmed against
  `feat/119-e2e`: envelope wrap `metrics_controller.ex:15,20,25,30`; decoders `Api.elm:2674,2760,2834,2877`;
  trend `"flat"` `Api.elm:2800,2810-2812`; cost label `Metrics.elm:312,326,391-400`. Layer 10 baseline:
  `Page.Admin.Metrics` has zero program tests (only `SessionExpiryPagesTest.elm:123-141`, a sad-path unit test).
