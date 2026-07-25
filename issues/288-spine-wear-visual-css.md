# Issue #288: Visual Wear-Level Distinction on Spines (CSS)

## Summary
Implement a visible CSS distinction between `Pristine` and `Softened` spine wear — today wear affects ONLY the aria-label suffix (", well-loved"); no wear-specific class or style exists (verified 2026-07-23, `Spine.elm:264-270` — WearLevel never reaches a class/style attribute). De-scoped from Issue #113, whose E2E asserts the aria-level distinction only.

## User Stories
- US-1.3.2 — Spine Wear by Engagement (the visual-rendering slice; de-scoped from #113 at epic kickoff 2026-07-23)

## Goal
Softened spines are visibly distinct from pristine ones (e.g. muted colour, softened edges, worn texture overlay) per the dark-academic aesthetic, and the distinction is assertable in Playwright.

## Scope Check
All four checks: No (CSS + a class hook in one Elm component).

## Wiring
Router wiring: n/a — visual change to existing rendering; user-facing on completion.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.3.2 (visual wear slice) | `Spine.book` emits `book--softened` (`Spine.elm:293` `wearClass`) → `.book--softened .book__spine` filter+vignette (`main.css:3152`); wired via `Page/Bookshelf/Helpers.elm` + `ReadingPile.elm` `wearLevel` | Library (Softened) spine renders a non-`none` `filter` (`saturate(0.8) brightness(0.9)`), Wish List (Pristine) renders `filter: none` — observed live on :4000 (`spine-rendering.spec.ts:374`, 8/8 passed) | ✅ | Built end-to-end + observed live |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- `Components.Spine.book`: emit a wear class (e.g. `book--softened`) from the `WearLevel` argument; CSS in the frontend stylesheet applying the visual treatment (respect existing texture backgrounds).
- Design pass: agree the visual treatment with the owner (bookshelf design memory: 3D books, real textures, petargyurov-style hover) before implementation.
- Consider (do not build without a decision): consuming the backend 4-level wear (`Shelving.spine_data/1` `:new/:light/:moderate/:heavy`) instead of the static 2-level per-shelf config — currently fully decoupled. If pursued, that is its own issue (API surface + Elm type change).
- elm-test: class present iff Softened; E2E: computed-style distinction between a WishList (Pristine) and Library (Softened) spine.

## Reviewer Context
- Elm `WearLevel` is `Pristine | Softened` only (`Spine.elm:17-19`) — do not invent a third tier here.
- Spine textures are static assets under `/textures/`; availability is asserted in `e2e/tests/assets.spec.ts`.

## Test Audit

_Compact audit (format A) — the 13 layers, each `yes` (✅ + a test citation verified by grep/Read against the shipped suites) or `n/a`-with-rationale. This is a pure client-side rendering slice: `Components.Spine.book` emits a `book--softened` class from the existing `WearLevel` arg + CSS. The entire server/data half of the stack is genuinely not applicable._

Last generated: 2026-07-25 (post-implementation compact audit)

Legend: ✅ = real coverage | n/a = not applicable (one-line reason).

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1. API calls | no | n/a — a pure client-side CSS class from the existing `WearLevel` arg; no server round trip. |
| 2. Auth & middleware guards | no | n/a — no endpoint. |
| 3. Database interactions | no | n/a — the wear class comes from the static per-shelf config; no DB read. |
| 4. Event flow & lifecycle | no | n/a — rendering emits no events. |
| 5. Background jobs (Oban) | no | n/a — no job. |
| 6. External service calls | no | n/a — no external call. |
| 7. Storage | no | n/a — spine textures are static assets under `/textures/`; no storage operation. |
| 8. Cache | no | n/a — no cache interaction. |
| 9. dbt models | no | n/a — no persisted data or dbt model. |
| 10. Elm frontend state machine | yes | ✅ `SpineBookTest.elm:308` (Softened book has the `book--softened` class), `:313` (Pristine book has no `book--softened` class), `:318` (Softened + hidden composes `book`, `book--hidden` and `book--softened`); E2E computed-style `spine-rendering.spec.ts:379` (a Softened shelf spine carries a muted worn `filter` a Pristine one lacks — live). |
| 11. Operational metrics | no | n/a — SLO gate (`scripts/check-slo-gate.sh`). |
| 12. Performance & usability | no | n/a — SLO gate. |
| 13. Cost tracking | no | n/a — pure CSS render. |

Tally: 1 ✅ / 12 n/a — 0 ❌, 0 ⚠️. GREEN.

## Definition of Done
- [x] Softened vs Pristine visually distinct and Playwright-assertable — evidence: `SpineBookTest.softenedBookHasWearClass` (3 tests: class iff Softened, composes with `book`/`book--hidden`) + `spine-rendering.spec.ts:374` computed-style `filter` distinction (Softened=`saturate(0.8) brightness(0.9)`, Pristine=`none`) — **8/8 spine E2E passed live on :4000**
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story**
- [x] Every behaviour has a validation path — elm-test (Elm class emission) + Playwright (live computed style)
- [x] Tests written and passing (`elm-test`) — `SpineBookTest` 33/33 pass (`npx elm-test tests/SpineBookTest.elm`)
- [~] Standards compliance verified — elm-format `--validate` clean, elm-review clean on my files (only pre-existing `elm.json` unused-dep noise remains), full-suite `elm-test` 1020 pass / 3 fail (the 3 are `Page.Search`, another agent's in-flight work, not this change). Branch-wide `just verify` deferred to the integrator (shared branch has concurrent in-flight failures outside this change).
- [x] **Test audit is GREEN** — compact audit generated + citations verified 2026-07-25 (this section).
- [x] **`completion-audit` skill passed on the integrated branch** — integration-time gate. — evidence: epic completion-audit PASS 2026-07-25 — adversarial spot-verification of all 16 children found zero false evidence tokens; its 3 finalization blockers cleared (CVE fix 32b2a18c + ci green, compact audits 8eaf4bb6, preview E2E below)
- [x] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — integration-time gate. — evidence: Completion Bar met at epic level 2026-07-25 — every deliverable driven live locally (per-issue Pre-Check) AND on the deployed preview: full run 250 passed/10 failed/10 skipped (all 10 failures = helper-502 machine-churn signature) with all 10 passing the single documented environmental retry (12/12, exit 0); logs scratchpad/preview-e2e-run2.log + preview-e2e-retry10b.log

## Dependencies
- Issue #113 (spine E2E harness)
- Owner design decision on the wear treatment

## Agent Assignment
`elm-agent` (+ `ux-reviewer` advisory on the treatment).

## Progress Notes
- 2026-07-23 — Created at #115/#114/#113 epic kickoff: visual-wear slice de-scoped from #113 (only the aria suffix exists; #113 asserts aria-level distinction).
- 2026-07-24 — Implemented the owner-approved (2026-07-24) **muted + worn edges** treatment. `Components.Spine.book` now emits a `book--softened` class from the `WearLevel` arg (type unchanged: `Pristine | Softened`), composed with `book`/`book--hidden`. CSS `.book--softened .book__spine` applies `filter: saturate(0.8) brightness(0.9)` plus a corner-wear vignette via `::after` — respects the existing texture backgrounds, leaves the 3D structure/hover untouched. Tests: `SpineBookTest.softenedBookHasWearClass` (class iff Softened + composition), extended `spine-rendering.spec.ts` with a computed-`filter` distinction between a Library (Softened) and Wish List (Pristine) spine. Gates: elm-test `SpineBookTest` 33/33, full-suite 1020 pass (3 fails are unrelated `Page.Search` in-flight work), elm-format `--validate` clean, elm-review clean on changed files, assets rebuilt (`apps/core/assets` `npm run deploy`), **spine E2E 8/8 passed live on :4000** (1 by-design skip: null page_count). Files: `frontend/src/Components/Spine.elm`, `frontend/css/main.css`, `frontend/tests/SpineBookTest.elm`, `e2e/tests/spine-rendering.spec.ts`.
