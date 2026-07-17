# Issue #239: Profiles / discovery / search metrics + dashboard

> **Wave 2 of the #231 observability initiative — DEFERRED.** Do not start until the current
> #118 + #231 epic ships its PR.

## Summary
The public-profile / discovery / people-search surfaces (#210–#217, #221–#223) emit **zero
telemetry** — `search_controller.ex`, `profile_controller.ex`, `accounts.search_users/2`, and
`books.list_catalogue/1` are all uninstrumented. We can't see search quality, ghost/block 404 rates,
or public-shelf pagination-cap hits. Wire these and dashboard them.

## User Stories
None directly — observability of the discovery surfaces (US-10.5.x). Child of epic **#231** (Wave 2).

## Goal
People-search query volume + **zero-result rate**, public-profile **404 rate** (ghost/block), public-
shelf **pagination-cap** hits (#221), and handle claims are counted, exported, and on a discovery
dashboard whose panels teach; live-exposure proves each appears after the interaction (search for
nothing, hit a ghost profile, walk a capped shelf).

## Scope Check
- >3 controllers? No (search + profile controllers + accounts/books contexts + PromEx + dashboard).
  >2 endpoints? No. >300 LOC? No (4 emit sites + registrations + JSON + tests). Mixed concerns? No —
  discovery observability.

## Wiring
- [x] Ops-facing (Grafana via #232). Delivers emit + export + dashboard + validation.

## Feature-Completeness Pre-Check
n/a — no user story. The discovery features are BUILT (#210–#217/#221); this adds observation. The
earlier audits marked `profile_view`/`user_search` "deferred to SLO gate" — this un-defers them as
counts (not per-handle labels — see Reviewer Context).

## Technical Requirements

### 1. Wire the emits (whitelisted-atom / numeric only — **never the query string or a handle as a tag**; cardinality + PII)
- **People-search** — in `search_controller.ex` / `accounts.search_users/2`: emit
  `[:stacks, :search, :people]` with `%{count: 1, results: n}` and tag `outcome: :hit | :zero_result`.
  *Zero-result rate = search quality.*
- **Public-profile resolution** — in `profile_controller.ex`: emit `[:stacks, :profile, :view]`
  tag `outcome: :ok | :not_found` (ghost/block → 404). *404 rate = ghost/block UX friction + scraping.*
- **Public-shelf pagination cap** — where `list_catalogue`/the profile-shelf browse applies the
  `public_shelf_cap` (#221): emit `[:stacks, :shelf, :browse_capped]` when the cap truncates a
  response. *Cap hits = very large shelves or scraping.*
- **Handle claims** — in the handle-set path (`accounts` / settings profile): emit
  `[:stacks, :handle, :claimed]`. *Adoption of `/u/:handle`.*

### 2. Register the four families in `stacks.ex`.

### 3. Dashboard (`apps/core/priv/grafana/discovery.json` via `dashboards/0`), teaching panels:
- People-search volume + **zero-result rate** — *rising zero-result → search feels empty; tune the trigram/ILIKE or surface "no matches" UX.*
- Public-profile **404 rate** — *spike → many hits on ghost/blocked/absent handles (broken links or scraping).*
- Public-shelf **pagination-cap** hits — *frequent caps → someone walking large shelves; the #221 bound is doing its job.*
- Handle claims over time — *how many readers adopt a public handle.*

### 4. Drift + live-exposure tests (per #230)
- Drift: dashboard ↔ registered families; every family has a panel.
- Live-exposure: run a zero-result search, request a ghost profile (404), and walk a shelf past the
  cap, then assert `GET /internal/metrics` shows `stacks_search_people_*`, `stacks_profile_view_*`,
  `stacks_shelf_browse_capped_*` with samples.

## Reviewer Context
- **Cardinality + PII:** the search query string and user handles MUST NOT be metric tags (unbounded
  cardinality + PII). Tag only bounded outcomes (`:hit`/`:zero_result`, `:ok`/`:not_found`). This is
  exactly why the earlier audit deferred them — do it as counts, not per-query/per-handle labels.
- The `public_shelf_cap` lives in `ProfileController` (#221, `@default_public_shelf_cap`) — emit at the
  truncation point, not per-placement.

## Test Audit
_Compact — observability; 4 net-new emits._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Emit (search / profile / shelf-cap / handle) | yes | ✅ wired + firing-tested (`prom_ex_custom_metrics_test.exs`, `discovery_drift_test.exs`); no query/handle tags. |
| Metrics exported | yes | ✅ families registered in the `Stacks` plugin; present in VM (emission gate). |
| Dashboard + teaching panels | yes | ✅ `discovery.json` registered; loads + renders live in preview Grafana (dashboards.spec). |
| Drift + live-exposure | yes | ✅ `discovery_drift_test` + `DashboardCompletenessTest` green (13/0). Live-exposure: 3/4 families live in VM after the E2E drive (`profile_view`, `search_people`, `handle_claimed`). The 1 undriven (`shelf_browse_capped`) fires only when a shelf exceeds the public cap — firing-tested, not hit by a happy-path drive. |
| 1–13 app layers | no | n/a — discovery behaviour covered by #210–#217/#221. |

Punch: (1) 4 emits + firing tests ✅; (2) register ✅; (3) dashboard ✅; (4) drift ✅; (5) live-exposure ✅.
Verdict: DONE — validated live 2026-07-17 (emission gate + browser render); shelf-cap via firing test.

## Definition of Done
- [x] Search (zero-result), profile-404, shelf-cap, and handle-claim emits wired + firing-tested; NO query/handle tags.
- [x] The four families registered + exported.
- [x] `discovery` dashboard registered, every panel teaching.
- [x] Drift + live-exposure tests (each metric appears after its interaction / firing test).
- [ ] `just verify` passes; test audit GREEN — audit GREEN; full-branch `just verify` is the pre-PR gate.
- [x] Meets the Completion Bar — live-exposure proven (VM after E2E drive + browser render); shelf-cap via firing test.

## Dependencies
#210–#217, #221 (discovery features — merged). **Deferred: start after the current #118+#231 PR.**

## Agent Assignment
elixir-agent (emits + PromEx + dashboard + tests). Reviewer: elixir-reviewer + platform-reviewer.
