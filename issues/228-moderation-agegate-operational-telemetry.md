# Issue #228: Operational telemetry for the moderation funnel + age-gate

## Summary
The moderation pipeline and the age-gate enforcement/verification path emit no operational
counters, so the funnel is unobservable: we cannot see step-by-step rejection rates
(not-a-book / ISBN-not-found / age-gated), compound-title expansion frequency, how often the age
gate blocks vs passes, or the age-verification success/failure split. Instrument these with
`:telemetry` events and firing tests.

## User Stories
US-4.1 §13 (moderation operational metrics), US-4.2 §13 (age-gate & verification metrics). Child of
epic **#118**.

## Goal
Every stage of the moderation funnel and every age-gate decision emits a `:telemetry` event that the
existing metrics pipeline (PromEx / `/internal/metrics`, scraped by the SLO gate) can aggregate,
each covered by a firing test that asserts the event is emitted with the right measurements/metadata.

## Scope Check
- More than 3 controllers? **No** — one controller (`UserSettingsController`) + one context
  (`Moderation`) + one plug (`AgeGate`).
- More than 2 new endpoints? **No** — none.
- Exceeds ~300 LOC production? **No** — ~6 `:telemetry.execute` call-sites + measurement plumbing
  (~120 LOC) + tests.
- Combines unrelated concerns? **Borderline** — moderation-funnel metrics (US-4.1) and age-gate
  metrics (US-4.2) are two stories, but they are the same *concern* (observability of the
  moderation/age-gate feature this epic validates) and share the telemetry test-harness. Kept
  together deliberately; if review finds them awkward, US-4.2's counters split to a follow-up.

## Wiring
- [ ] Router wiring / user-facing.
- [x] Implementation only — telemetry emission consumed by the existing PromEx plugin +
      `scripts/check-slo-gate.sh` (`/internal/metrics`). No new route/UI.

## Feature-Completeness Pre-Check
Both stories' happy paths are **built** (verified feat/118-e2e). This issue adds observability that
§13 of each story specifies but which was never instrumented — build-in-scope, not a missing story.

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-4.1 — Moderation pipeline | `moderation.ex:55` run_pipeline → analyze `:83` → step branches (`not_a_book`/`isbn_not_found`) → `expand_compound_candidates/1` `:111` → `determine_visibility_tier/1` `:402` | ✅ built; only `[:stacks,:enrichment,:candidate,:skipped]` telemetry exists today (`:273`) — no step-rate counters | ✅ built (metrics gap) | build in-scope |
| US-4.2 — Age verification | `age_gate.ex:42` enforce (403 vs pass) ; `user_settings_controller.ex:13` update_age_verification (200 vs 422) | ✅ built; zero telemetry in either (`grep telemetry` → none) | ✅ built (metrics gap) | build in-scope |

Verdict: ✅ implemented · 🟡 partial · ❌ missing.

## Technical Requirements

### 1. Moderation funnel telemetry (`apps/core/lib/stacks/moderation.ex`)
Emit `:telemetry.execute` at each outcome (metadata includes an `image_id`/correlation where
available, never PII):
- **Step 1 — classification:** `not_a_book` / `ambiguous` / `book` outcome counter (the `/analyze`
  short-circuit branches).
- **Step 2 — ISBN resolution:** `isbn_not_found` vs `resolved` counter (per-candidate and/or
  per-pipeline).
- **Step 3 — age-gate tiering:** `age_gated` vs `public` counter (from `determine_visibility_tier/1`).
- **Compound-title expansion:** a counter/measurement for how often `expand_compound_candidates/1`
  splits a `" OR "`-joined title (and into how many).
- Event name convention: follow the existing `[:stacks, :enrichment, …]` / `[:stacks, :moderation, …]`
  namespace; reuse the `Stacks.Telemetry` helper if one fits. Measurements are counts (`%{count: 1}`)
  with outcome in metadata.

### 2. Age-gate enforcement telemetry (`apps/core/lib/stacks_web/plugs/age_gate.ex`)
- Emit on `enforce/2` for an `age_gated` book: `blocked` (403) vs `passed` outcome counter.
- Do not emit for non-age-gated passthrough (that path is the common case; count only age-gate
  decisions).

### 3. Age-verification request telemetry (`apps/core/lib/stacks_web/controllers/user_settings_controller.ex`)
- Emit on `update_age_verification/2`: `success` (200) vs `invalid` (422) outcome counter.

### 4. Metrics registration
- Register the new metrics in the PromEx plugin (`apps/core/lib/core/prom_ex/plugins/stacks.ex`) so
  they surface at `/internal/metrics` for the SLO gate. Confirm names/labels match the scrape
  expectations.

### 5. Firing tests
- For each emitted event, a test that attaches a handler and asserts the event fires with the
  expected measurements + metadata — **pattern:** `apps/core/test/stacks/upload_telemetry_test.exs`
  (`:telemetry_test.attach_event_handlers` / `assert_receive`). Cover the happy outcome AND at least
  one sad outcome per counter (e.g. `blocked` and `passed`; `success` and `invalid`).

## Reviewer Context
- Telemetry metadata must carry **no PII** (no email, no raw user identifiers beyond an opaque id
  where strictly needed) — GDPR: metrics/telemetry are a warehouse-adjacent sink.
- Existing telemetry patterns: `Stacks.Telemetry.phase/…` (durations, `moderation.ex:143/387`),
  `[:stacks,:enrichment,:candidate,:skipped]` (`moderation.ex:273`), and the Oban `[:oban,:job,:stop]`
  assertions in `upload_telemetry_test.exs`. Match the namespace + measurement shape.
- Layers 11/12 are normally `n/a — SLO gate`; this issue is the exception that *builds* the L11
  counters §13 calls for, so its own Test Audit L11 must go ✅ (firing tests), not `n/a`.
- The SLO gate (`scripts/check-slo-gate.sh`) scrapes `/internal/metrics`; new metrics must be
  registered in the PromEx plugin or they won't appear.

## Test Audit

_Baseline (13 layers × 2 US, happy/sad), generated 2026-07-15 (pre-implementation). This is the
mirror-image of #118's audit: there L11 was the only soft row and every feature layer was ✅; here
**L11 is the only non-`n/a` layer and it is ❌ for both stories** — the whole point of the issue.
Every ✅ inherited unchanged from #118; every claim grep/Read-verified on `feat/118-e2e`._

Legend: ✅ real · ⚠️ shallow · ❌ missing · n/a (reason)

### Feature status — the funnel is unobservable today (grep-verified)
**US-4.1:** `moderation.ex` emits exactly ONE `:telemetry.execute` —
`[:stacks,:enrichment,:candidate,:skipped]` (`moderation.ex:273-277`, low-confidence skips only) —
plus two `Stacks.Telemetry.phase` **duration** spans (`:143` isbn_resolution, `:387` persistence).
No counter on step-1 branches (`analyze/2` `book` `:87` / `isbn_not_found` `:84` / `not_a_book`+`ambiguous`
`:100`), step-2 resolve/reject (`:181-185`, `title_fallback` `:380`), step-3 tier
(`determine_visibility_tier/1` `:402-408`), or compound-expansion (`expand_compound_candidates/1` `:111`).
The job-level `[:stacks,:upload,:terminal]` counter collapses the whole pipeline into one outcome —
it cannot break the funnel down by step.
**US-4.2:** `grep telemetry age_gate.ex` → **none** (`enforce/2` `:42`: pass `:46`, 403 `:48`, passthrough
`:55`); `grep telemetry user_settings_controller.ex` → **none** (`update_age_verification/2` `:13`: 200
`:18`, 422 `:21`/`:28`). **PromEx:** `prom_ex/plugins/stacks.ex:59` registers no moderation/age-gate/verify
family (`grep "visibility\|age_gat"` → nothing) — even if emitted, counters wouldn't reach `/internal/metrics`.

### Framework-layer summary
| Layer | US-4.1 (funnel) | US-4.2 (enforce + verify) |
|-------|-----------------|---------------------------|
| Elixir behaviour | ✅ unchanged (`moderation_test.exs` 25, `identify_book_job_test.exs`) | ✅ unchanged (`age_gate_test.exs` 7, `user_settings_controller_test.exs` age-verify 4) |
| **Elixir telemetry (L11)** | ❌ no funnel step/expansion counters | ❌ zero telemetry in `age_gate.ex` + `user_settings_controller.ex` |
| PromEx registration | ❌ no moderation family | ❌ no age-gate/verify family |
| Elm / Python / dbt / E2E | n/a — server-side `:telemetry`, no client/sidecar/warehouse/browser surface | n/a — same |

**Existing-test inventory (grep/read — the firing-test PATTERN to follow):**
- `upload_telemetry_test.exs` — **46** tests. `attach_telemetry/1` `:88`, `attach_telemetry_filtered/2` `:105`; `"[:oban,:job,:stop] fires for IdentifyBookJob"` `:281`, cancellation not_a_book `:328`, isbn_not_found `:357`; custom `[:stacks,:events,:handler_error]` `%{count:1}` `:137/:166`.
- `observability_telemetry_test.exs` — **8**. `[:stacks,:vision,:request,:start|:stop]` `:39`, `[:stacks,:budget,:cost_recorded]` `:113`, `[:stacks,:costs,:recorded]` `:163`.
- `upload_terminal_telemetry_test.exs` — the closest analogue: `[:stacks,:upload,:terminal]` outcome `:resolved` `:69` / `:rejected` `:118` / `:timeout` `:148` + negative `:172`. Job-terminal, NOT per-step — does not satisfy §13.
- `visibility_telemetry_test.exs` — fresh per-feature telemetry suite precedent (#197): `assert_receive {:telemetry_event, [:stacks,:visibility,:profile_change], %{count:1}, …}` `:64`, whitelisted-atom metadata (GDPR "no raw user input as a tag").
- **Confirmed absent:** no test attaches to a moderation step-rate, compound-expansion, AgeGate-enforce, or age-verify event; no `moderation_telemetry_test.exs` exists.

### Full audit (13 layers × 2 US; only L11 is in-scope work — others inherited unchanged from #118)
| Layer | US-4.1 | US-4.2 |
|-------|--------|--------|
| 1 API · 2 auth · 3 DB | ✅ unchanged (`upload_controller_test.exs`; `age_gate_test.exs:45/:29/:36`, `user_settings_controller_test.exs:18/:40/:52`) | ✅ unchanged |
| 4 event | n/a — `:telemetry` is a metrics sink, must NOT reach event_log | n/a — age-verify emits no domain event |
| 5 Oban | n/a — counters fire in-line in `run_pipeline/1`; Oban lifecycle already `upload_telemetry_test.exs:281` | n/a — synchronous, no job |
| 6 external · 7 storage · 8 cache · 9 dbt | n/a — telemetry observes; no new external/storage/cache/warehouse surface | n/a |
| 10 Elm | n/a — server-side telemetry, no Elm surface | n/a |
| **11 metrics (happy+sad)** | ❌❌ no step1/2/3 or compound-expansion counters; no firing test; no PromEx family | ❌❌ no enforce blocked-vs-passed, no verify success-vs-invalid; no firing test; no PromEx family |
| 12 perf | n/a — SLO gate (counts, not latency SLAs) | n/a |
| 13 cost | n/a — Modal cost `budget_tracker_test.exs`/`observability_telemetry_test.exs:113` | n/a |

### Coverage tally
| ✅ (inherited) | ⚠️ | ❌ (L11 × 2 US × happy/sad) | n/a |
|---|---|---|---|
| 6 | 0 | 4 | 42 |

52 cells (13 × 2 × happy/sad). The 4 ❌ collapse into 2 punch items.

### Punch list (baseline — 0 resolved)
| # | Cell | What's needed | Where |
|--:|------|---------------|-------|
| 1 | L11 US-4.1 (happy+sad) | Instrument step-1 (`book`/`not_a_book`/`ambiguous`, `analyze/2` `:84/:87/:100`), step-2 (`resolved`/`isbn_not_found`, `:181-185`/`:380`), step-3 (`age_gated`/`public`, `:402`), compound-expansion (`:111`). `[:stacks,:moderation,…]` namespace, `%{count:1}`, **whitelisted-atom** outcome metadata (no PII). Register in `prom_ex/plugins/stacks.ex`. Add `moderation_telemetry_test.exs` — happy + ≥1 sad firing test per counter (pattern `upload_telemetry_test.exs:88`). | `moderation.ex`, `prom_ex/plugins/stacks.ex`, new `moderation_telemetry_test.exs` |
| 2 | L11 US-4.2 (happy+sad) | `AgeGate.enforce/2` (`:42`) blocked (403 `:48`) vs passed (`:46`) — emit only for the `age_gated` clause, not passthrough (`:55`). `update_age_verification/2` (`:13`) success (200 `:18`) vs invalid (422 `:21`/`:28`). Whitelisted-atom metadata, no PII. Register in PromEx. Firing tests happy+sad (pattern `visibility_telemetry_test.exs`). | `age_gate.ex`, `user_settings_controller.ex`, `prom_ex/plugins/stacks.ex`, new telemetry test(s) |

### Verdict
**Baseline — the moderation funnel is unobservable today. 4 ❌ (L11 both US, happy+sad) → 2 punch
items; 6 ✅ inherited; 42 n/a.** Headline: (1) `moderation.ex` has one `:skipped` counter + two
duration spans and no per-step funnel counters; the coarse `[:stacks,:upload,:terminal]` can't break
it down; (2) `age_gate.ex` + `user_settings_controller.ex` have zero telemetry (grep); (3) PromEx has
no home for these (`prom_ex/plugins/stacks.ex:59`) — registration folded into both punches; (4) the
`attach → exercise → assert_receive` pattern already exists and passes — no new harness needed.
Telemetry-test totals (grep): `upload_telemetry_test.exs` **46**, `observability_telemetry_test.exs`
**8**, plus terminal/visibility/gdpr suites — **zero** attach to a moderation-step, AgeGate-enforce, or
age-verify event. Done when both L11 cells go ✅.

## Definition of Done
- [ ] Moderation funnel emits step1/step2/step3 + compound-expansion telemetry, each with a firing test (happy + ≥1 sad outcome).
- [ ] `AgeGate.enforce/2` emits blocked-vs-passed telemetry for age-gated books, with a firing test.
- [ ] `update_age_verification/2` emits success-vs-invalid telemetry, with a firing test.
- [ ] New metrics registered in the PromEx plugin and visible at `/internal/metrics`.
- [ ] Telemetry metadata carries no PII (GDPR-reviewed).
- [ ] Feature-Completeness Pre-Check remains ✅ for US-4.1 + US-4.2.
- [ ] `just verify` passes.
- [ ] Test audit (above) GREEN — both L11 cells ✅, 0 ❌/⚠️.
- [ ] Meets the Completion Bar — metrics **asserted** (firing tests), not assumed.

## Dependencies
Independent of #227/#229 at the file level (touches `moderation.ex` telemetry, `age_gate.ex`,
`user_settings_controller.ex`, PromEx plugin — no overlap with #227's `books.ex:182` emit or #229's
catalogue filter). Runs in parallel (Level 0). Integration branch: `feat/118-e2e`.

## Agent Assignment
elixir-agent (reviewer: elixir-reviewer; GDPR-review skill as a lens on telemetry metadata).
