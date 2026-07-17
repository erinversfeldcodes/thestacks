# Issue #236: Export visibility/social/ViewAs metrics to PromEx + dashboard

> **Wave 2 of the #231 observability initiative — DEFERRED.** Do not start until the current
> #118 + #231 epic ships its PR. Authored now for planning; sits in the backlog behind #232–#235.

## Summary
#197 instrumented ~8 visibility/social/ViewAs telemetry events (emit + firing tests) but **never
registered them in PromEx** — they fire and are log-reported but are **absent from
`/internal/metrics`**, so nothing scrapeable/dashboardable exists. Register them and build a
self-explanatory dashboard.

## User Stories
None — observability of the visibility/social system (US-10.x). Child of epic **#231** (Wave 2).

## Goal
Every visibility/social/ViewAs counter #197 emits is exported at `/internal/metrics` and appears on a
Grafana dashboard whose panels teach; a drift test keeps dashboard ↔ registered metrics in sync; a
live-exposure test proves the families appear after real interaction (change a profile's visibility,
block a user, use ViewAs).

## Scope Check
- >3 controllers? No (PromEx plugin + dashboard JSON + tests). >2 endpoints? No. >300 LOC? No
  (registrations + JSON + tests). Mixed concerns? No — one concern: export + dashboard the visibility
  metrics.

## Wiring
- [x] User-facing at the ops layer (renders on Grafana via #232). Delivers export + dashboard + validation.

## Feature-Completeness Pre-Check
n/a — no user story. The metrics EMIT already exists (#197, `visibility_telemetry_test.exs`); the gap
is the PromEx export + dashboard, both validated by the tests below.

## Technical Requirements

### 1. Register the emitted-but-unexported families in `apps/core/lib/core/prom_ex/plugins/stacks.ex`
(events confirmed emitted today; mirror the existing counter/2 style):
- `[:stacks, :visibility, :profile_change]` (tag `direction`) — `visibility.ex:578`
- `[:stacks, :visibility, :ceiling_rejection]` (tag `resource_type`) — `visibility.ex:601`
- `[:stacks, :visibility, :recap]` (tag `outcome`; measurements `bookshelves_capped`/`placements_capped`/`posts_capped`) — `workers/visibility_recap_job.ex:45/74/105`
- `[:stacks, :social, :block]` — `social/social.ex:99`
- `[:stacks, :social, :unblock]` — `social/social.ex:156`
- `[:stacks, :social, :block_error]` (tag `reason`) — `social/social.ex:114`
- `[:stacks, :view_as, :usage]` (tag `perspective`) — `plugs/view_as_plug.ex:131`
- `[:stacks, :view_as, :error]` (tags `reason`, `phase`) — `plugs/view_as_plug.ex:135`
- (`:rate_limit_social` is already exported via the generic `stacks_rate_limit_rejected_count_total{bucket}` — do NOT duplicate.)

### 2. Dashboard (`apps/core/priv/grafana/visibility_social.json`, registered via `dashboards/0`)
Panels (each with a teaching `description` per the #233 standard — what/how/what-it-means/what-a-change-indicates):
- Profile-visibility changes by `direction` (how often profiles go private vs public) — *spike toward "more private" → a privacy/UX event worth understanding.*
- Block / unblock counts + block_error by reason — *block spikes → harassment wave or a UX regression.*
- ViewAs usage by `perspective` + errors — *adoption of the owner-preview feature; errors → a broken perspective.*
- Ceiling-rejections by `resource_type` — *users trying to set content more open than their profile allows → confusing UX.*
- Visibility-recap outcomes + capped counts — *how often the recap job tightens shelves after a profile goes private.*

### 3. Drift test + live-exposure test (per #230)
- Drift: dashboard panels reference only registered families, and every family in §1 has ≥1 panel.
- Live-exposure: change a profile's visibility, block+unblock a user, and exercise ViewAs, then assert
  `GET /internal/metrics` (with `METRICS_SCRAPE_TOKEN`) contains the `stacks_visibility_*` /
  `stacks_social_*` / `stacks_view_as_*` families with samples.

## Reviewer Context
- Metrics tags must be **whitelisted atoms** (no handle/email/user-id as a tag) — GDPR: telemetry is
  warehouse-adjacent (mirror the `visibility_telemetry_test.exs` discipline).
- #197 delivered the EMIT; this is the EXPORT + dashboard follow-up — do not re-instrument.
- This directly feeds the #234 user-facing transparency surface ("what we observe about your
  visibility & blocks").

## Test Audit
_Compact — observability. Load-bearing: registration present, drift, live-exposure._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Metrics exported (PromEx registration) | yes | ✅ families registered in `Core.PromEx.Plugins.Stacks`; present in VM (`dashboard-emission-gate.sh`). |
| Dashboard exists + registered + teaching panels | yes | ✅ `visibility_social.json` registered via `dashboards/0`; loads + renders live in preview Grafana (`e2e/tests/dashboards.spec.ts`). |
| Drift (dashboard ↔ registered) | yes | ✅ `visibility_social_drift_test` + `DashboardCompletenessTest` green (13/0 — displayed ⊆ measured, no dead panels). |
| Live-exposure after interaction | yes | ✅ 8/11 referenced families live in VM after the preview E2E drive (emission gate); browser render asserts live panels paint. The 3 undriven (`social_block_error`, `view_as_error`, `visibility_ceiling_rejection`) are error/rejection paths — registered + panel-backed, fire only on those paths, not a happy-path drive. |
| 1–13 app layers | no | n/a — the emit + behaviour are already covered by #197/#122 tests. |

Punch: (1) register families ✅; (2) dashboard + teaching panels ✅; (3) drift test ✅; (4) live-exposure test ✅.
Verdict: DONE — validated live 2026-07-17 on preview stack (emission gate + browser render).

## Definition of Done
- [x] All visibility/social/ViewAs families registered in PromEx and exported — present in VM (emission gate).
- [x] `visibility_social` dashboard registered via `dashboards/0`, teaching panels; renders live (dashboards.spec).
- [x] Drift test + live-exposure — drift/completeness green (13/0); live-exposure via emission gate + browser render.
- [x] `just verify` passes; test audit GREEN — full-branch `just verify` GREEN 2026-07-17 (elixir/dialyzer/credo/sobelow, elm 855, dbt 231).
- [x] Meets the Completion Bar — live-exposure proven (families in VM after E2E drive + browser paints), not assumed.

## Dependencies
#197 (emit — merged). Independent of #232 (validated without live Grafana). **Deferred: start after the
current #118+#231 PR.**

## Agent Assignment
elixir-agent (PromEx registration + dashboard + tests). Reviewer: elixir-reviewer + platform-reviewer.
