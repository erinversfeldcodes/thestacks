# Issue #262: US-5.1 Metrics Dashboard — Backend Data Completeness

## Summary
Fill the backend data gaps in `Stacks.Admin.Metrics` that leave the admin metrics
dashboard's Source Health, Enrichment Gaps, and Data-Quality-Trend sections empty
without dbt marts, and make `source_health/0` emit the exact wire shape the frontend
`SourceHealth` decoder consumes. Implementation fix spun out of #119's E2E pre-check.

## User Stories
US-5.1 (admin metrics dashboard). This is an implementation-completeness fix behind
an already-built story surface — the dashboard, controller, routes, and Elm page exist;
their backing data queries are incomplete.

## Goal
Every metrics dashboard section returns real data on a stack **without** dbt marts
(local, CI, fresh preview):
1. `source_health/0` returns `last_success_at`/`last_failure_at` and serializes as
   `{name, sourceType, status, consecutiveFailures, lastSuccess, lastFailure}` — the
   shape `Api.elm`'s `SourceHealth` type + #261's `getSourceHealth` decoder expect.
2. `enrichment_gaps/0` and `quality_trends/0` return real live-query aggregations
   (mirroring `system_health/0`'s fallback) instead of empty stubs when the marts are absent.
3. `op.source_health_checks` is seeded with representative rows so the Source Health
   section is non-empty in dev/E2E.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Controllers touched: **0 changed** (1 read — `metrics_controller.ex` already wraps
  every section in the `%{data: …}` envelope; the shape is built in the context). → OK.
- New endpoints: **0** (existing `/api/metrics/source-health`, `/enrichment-gaps`,
  `/quality-trends`, `/api/metrics`). → OK.
- Production LOC estimate: `source_health/0` remap ~15, `enrichment_gaps/0` fallback ~25,
  `quality_trends/0` fallback ~25, seeds ~20 = **~85 LOC**. → under 300, OK.
- Mixed concerns: single concern (metrics backend data completeness) + its seed. → OK.
- **Split trigger (watch):** the mart-less enrichment/quality fallback should aggregate
  only over op tables reachable without dbt intermediates (books/editions/uploaded_images).
  If price-coverage / review-coverage gaps require joining new marketplace-price or
  review op tables and that balloons past ~300 LOC, **split the price/review coverage
  slice into its own issue** and land cover-coverage + counts here.

Verdict: **PASS — single issue, no split** (with the price/review-coverage split trigger noted).

## Wiring
Implementation-only — routes/controller/Elm page already wired (`metrics_controller.ex`, `Api.elm`
`SourceHealth`); frontend decode coordinated in #261.

## Feature-Completeness Pre-Check
<!-- US-5.1's dashboard surface is BUILT (routes, controller, Elm page, Metrics context all
exist). This issue completes the DATA behind three sections, it does not build a new story
surface. The named story's happy path (admin loads dashboard) is implemented; the gap is
sections rendering empty without marts. Full live-drive of the rendered dashboard is #119's
job. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-5.1 metrics dashboard | `metrics_controller.ex:14-31` (routes wired) → `metrics.ex` sections → `Api.elm:2595` `SourceHealth` | ⬜ browser drive is #119 | 🟡 partial | Data completeness built **in-scope** here (source_health fields+shape, enrichment/quality live fallbacks, seed). Surface already built. |

Verdict: 🟡 partial — the missing hops are all **data** (this issue's scope), not a deferred surface. Resolved in-scope.

## Technical Requirements

### 1. `source_health/0` — add fields + emit decoder-shaped map (`metrics.ex:134`)
Current SELECT (`metrics.ex:137`) returns
`source_name, source_type, status, consecutive_failures, total_successes, total_failures`
as raw snake_case-keyed maps. Two gaps:
- **Missing columns:** add `last_success_at`, `last_failure_at` (both present on
  `op.source_health_checks` / `Stacks.Monitoring.SourceHealthCheck:17-18`).
- **Wrong wire shape:** `Api.elm:2595-2602` `SourceHealth` expects keys
  `{name, sourceType, status, consecutiveFailures, lastSuccess, lastFailure}`.
  Map the query rows to exactly those keys (build the map in `source_health/0`,
  do not rely on raw column names). Serialize `last_success_at`/`last_failure_at`
  as ISO8601 strings or `null`.
- **String contract (embed in Reviewer Context):** `source_type` and `status` are
  plain strings in `op.source_health_checks` (schema fields are `:string`). **Return
  them as plain strings** — #261's decoder decodes strings, NOT proto enums. Do not
  coerce to proto `SourceType`/`HealthStatus` enums.

### 2. `enrichment_gaps/0` live fallback (`metrics.ex:149`)
Currently returns `%{status: "mart_not_available", gaps: []}` on `:fallback`. Add a
live-query fallback mirroring `system_health/0` (`metrics.ex:32`): aggregate over op
tables reachable without dbt intermediates. `mart_enrichment_gaps.sql` computes
`missing_cover`/`missing_prices`/`missing_reviews` + `gap_count` per book from
`int_book_detail_view`/`int_price_trends`/`int_review_sentiment`. The fallback cannot
join those intermediates; compute what op tables allow:
- **missing_cover** from `op.book_editions.cover_image_url IS NULL` per book (books with
  no edition carrying a cover). Return a summary the frontend can render (e.g.
  `%{total_books, missing_cover, ...}` and/or a bounded `gaps` list).
- Price/review coverage: degrade gracefully if the source op tables are absent (see the
  split trigger in Scope Check). Do not `:fallback` to an empty stub.

### 3. `quality_trends/0` live fallback (`metrics.ex:119`)
Currently returns `[]` when `wh.mart_data_quality_trend` is absent. Add a live-query
fallback producing at least a current-snapshot aggregation mirroring
`mart_data_quality_trend.sql`'s daily snapshot (`total_books`, `books_with_covers`,
`cover_pct`, plus price/review pct where reachable) over op tables. A single
current-week point is acceptable when no historical mart exists.

### 4. Seed `op.source_health_checks` (`seeds.exs`)
`seeds.exs` seeds none (no `source_health` insert). Add representative rows via
`Repo.insert_all("source_health_checks", …, prefix: "op", on_conflict: :nothing)`
(matching the file's existing `insert_all` pattern, e.g. `seeds.exs:989`) covering:
a **healthy** source, a **degraded** source (some `consecutive_failures`, a recent
`last_success_at`), and a **broken** source (`status: "broken"`, `last_failure_at`,
`last_failure_reason`). Use deterministic `Seeds.uuid(n)` IDs in a fresh range.

## Reviewer Context
- **`source_type`/`status` are plain strings** in `op.source_health_checks`, not proto
  enums. #262 emits strings; #261's `getSourceHealth` decoder decodes strings. Do not
  introduce proto-enum coercion on the wire — the Elm proto-enum adapter
  (`fromProtoSourceHealthCheck`, `Api.elm:2608`) is a *separate* path not used here.
- **Wire shape is built in the context, not the controller.** `metrics_controller.ex`
  only wraps `Metrics.source_health()` in `%{data: …}`; the camelCase keys
  (`sourceType`, `consecutiveFailures`, `lastSuccess`, `lastFailure`, `name`) must be
  produced by `source_health/0` itself.
- **Fallback pattern is established** — `system_health/0` (`metrics.ex:32`) and
  `gdpr_compliance/0` (`metrics.ex:102`) already do live-query fallbacks; enrichment/
  quality must follow the same `case query_mart(...) do {:ok, row} -> row; :fallback -> …`
  shape via the existing `query_mart`/`query_mart_rows` helpers.
- **Marts join dbt intermediates** (`int_book_detail_view`, `int_price_trends`,
  `int_review_sentiment`) that don't exist without dbt — the fallback must query op
  tables (`op.books`, `op.book_editions`, `op.uploaded_images`) directly, never the `int_*` views.
- **CROSS-CUTTING with #261 (same branch `feat/119-e2e`):** #261's `getSourceHealth`
  decoder consumes *exactly* the shape this issue emits — plain-string `source_type`/
  `status`, plus `last_success_at`/`last_failure_at`, list under `data`. They must land
  together. (#261 has no `issues/261-*.md` yet — it is a sibling on this branch, tracked
  by coordination here, not a file dependency.)
- **Generated schema — do not hand-edit** `Stacks.Monitoring.SourceHealthCheck`
  (`stacks/gen/`) is proto-generated (`mix proto.sync`); all needed columns already exist.

## Test Audit
<!-- Full-format not warranted: single context module + seed, no new US surface, no new
Elm state machine or endpoints. Layer-scoped audit against the real suites. -->

Existing coverage (verified by Read):
- `apps/core/test/stacks/admin/metrics_test.exs` — asserts each section returns the right
  *type* (map/list) on the **mart-missing fallback** branch only (`source_health/0`
  "returns a list", `enrichment_gaps/0` "returns fallback map", `quality_trends/0`
  "returns empty list"). It does **not** assert field presence, the wire-key shape, or
  real aggregation over seeded data. → shallow (⚠️) for this issue's behaviours.
- `apps/core/test/stacks_web/controllers/metrics_controller_test.exs` — asserts 200/401
  and `%{"data" => _}` presence for `/source-health`, `/enrichment-gaps`,
  `/quality-trends`; does **not** assert the serialized keys inside `data`. → shallow (⚠️).

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 3 — DB interactions / aggregation | yes | ❌ `source_health/0` returns new fields (`lastSuccess`/`lastFailure`) with correct keys over seeded rows; `enrichment_gaps/0` + `quality_trends/0` real live-query aggregation over seeded books **without a mart** (assert non-empty, correct counts) — extend `metrics_test.exs` (→ ✅ when done) |
| 1 — API shape | yes | ❌ `metrics_controller_test.exs` asserts the serialized `data` shape for `/source-health` = `{name, sourceType, status, consecutiveFailures, lastSuccess, lastFailure}` (plain strings), and non-empty `enrichment-gaps`/`quality-trends` with seeded data (→ ✅ when done) |
| 9 — dbt models | yes (inverted) | ❌ the point is the **mart-LESS** path — assert the live-query fallback fires and returns real data with no `wh.mart_*` present (default local/CI DB state); do **not** create marts here (→ ✅ when done) |
| seed presence | yes | ❌ assert `op.source_health_checks` is seeded (healthy/degraded/broken) so the section is non-empty — covered by the Layer 3 aggregation test running against seeded rows, or a `seeds.exs`-loaded assertion (→ ✅ when done) |
| 2 auth/middleware | yes | ✅ existing `metrics_controller_test.exs` 401 cases cover admin-MFA gate (unchanged) |
| 4 events · 5 Oban · 6 external · 7 storage · 8 cache · 10 Elm state · 11 metrics · 12 perf · 13 cost | no | n/a — pure read-side context data; no events/jobs/state-machine/cost surface introduced. Elm decode is #261. |

**Punch list**
1. Layer 3 — `metrics_test.exs`: `source_health/0` returns maps with keys
   `name/sourceType/status/consecutiveFailures/lastSuccess/lastFailure` over an inserted
   `SourceHealthCheck` (healthy + broken); `lastSuccess`/`lastFailure` are ISO8601 strings or nil.
2. Layer 3 — `metrics_test.exs`: `enrichment_gaps/0` returns real aggregation (non-empty,
   `missing_cover` count matches inserted editions with null cover) with **no mart present**.
3. Layer 3 — `metrics_test.exs`: `quality_trends/0` returns a real snapshot (`total_books`,
   `cover_pct`) with no mart present.
4. Layer 1 — `metrics_controller_test.exs`: assert the serialized `data` keys for
   `/api/metrics/source-health` (plain-string `sourceType`/`status`).
5. seed — representative rows present; the Layer 3 tests run against inserted fixtures
   (factory/`Repo.insert`), and `seeds.exs` gains the three demo rows for dev/E2E.

**Validation path per behaviour:** all behaviours are backend context/controller integration
tests (`Core.DataCase` / `CoreWeb.ConnCase`) — Playwright is the wrong tool; the rendered-
dashboard browser drive is #119's job. n/a for browser E2E here (rationale: read-side data
shape, proven at the context + API-envelope layer; UI render validated in #119).

Verdict: **BASELINE — 4 ❌ / 2 ⚠️ / 1 ✅.** Work queue = punch list 1–5.

## Definition of Done
- [ ] `source_health/0` returns `last_success_at`/`last_failure_at` and emits keys
      `{name, sourceType, status, consecutiveFailures, lastSuccess, lastFailure}` with
      plain-string `sourceType`/`status` — evidence: `metrics_test.exs "source_health/0 …"`
      + `metrics_controller_test.exs` data-shape assertion GREEN
- [ ] `enrichment_gaps/0` returns real live-query aggregation (no mart) — evidence:
      `metrics_test.exs "enrichment_gaps/0 aggregates over books without a mart"` → asserted counts
- [ ] `quality_trends/0` returns a real snapshot (no mart) — evidence:
      `metrics_test.exs "quality_trends/0 …"` → non-empty with `total_books`/`cover_pct`
- [ ] `op.source_health_checks` seeded (healthy/degraded/broken) — evidence:
      `seeds.exs` insert + `just run mix run apps/core/priv/repo/seeds.exs` → rows present
- [ ] Coordinated with #261: shape emitted here matches its `getSourceHealth` decoder on
      `feat/119-e2e` — evidence: branch integration note / #261 decoder test GREEN against this data
- [ ] **GDPR: N/A** — source-health, enrichment, and quality data are aggregate platform
      metrics with no user FK and no PII (`op.source_health_checks` has no user column;
      aggregations count books/editions/covers, not personal data). Seed rows are synthetic
      source names. No erasure/export/consent surface touched. — evidence: gdpr-review lens N/A rationale
- [ ] Every behaviour has a validation path — context/integration tests here; browser drive is #119
- [ ] Tests written and passing (`just run mix test apps/core/test/stacks/admin/metrics_test.exs
      apps/core/test/stacks_web/controllers/metrics_controller_test.exs`)
- [ ] Standards compliance verified (`just run just verify` passes)
- [ ] **Test audit (embedded above) is GREEN** — 0 ❌, 0 ⚠️; regenerate as the final step
- [ ] **`completion-audit` skill passed** on the integrated branch — cite the run
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — data
      observed real at the far end (section non-empty), tests asserted, logs clean; browser
      render deferred to #119 by design

## Dependencies
- **Coordinates with #261** (frontend `getSourceHealth` decoder) — both land on
  `feat/119-e2e`; #261 decodes exactly the shape #262 emits. No file dependency (#261 has
  no `issues/261-*.md` yet; sibling on the same branch).
- **Feeds #119** (E2E metrics-dashboard validation) — #119's browser drive of the rendered
  dashboard requires these sections to return data.
- No infra prerequisites; op tables (`op.source_health_checks`, `op.books`,
  `op.book_editions`) and routes already exist.

## Agent Assignment
**elixir-agent** (primary) — `Stacks.Admin.Metrics` context changes + `metrics_test.exs`/
`metrics_controller_test.exs`. May delegate the mart-less SQL aggregation design to
**database-agent** if the enrichment/quality fallback SQL is non-trivial. Includes the
`seeds.exs` `op.source_health_checks` fixture rows (elixir-agent).

## Progress Notes
(none yet)
