# Issue #289: Search Result Click-Through to Book Detail Overlay

## Summary
Make search results clickable: clicking a result on `/search` opens the book detail overlay (US-1.4.1 integration). Today `Page.Search.viewBookResult` renders a plain `div.search-result` with no click affordance, and `Page.Search.OutMsg` has only `NoOut | SessionExpired` — the US-1.5.1 "click a result → overlay opens" hop is unbuilt (verified 2026-07-23 during #115 Phase 3; `frontend/src/Page/Search.elm:366-377`).

## User Stories
- US-1.5.1 — Search Across Shelves (the result-click slice only; de-scoped from #115 at Phase 3, 2026-07-23)

## Goal
A user who finds a book via search can open its detail overlay directly from the results list, keyboard-accessibly.

## Scope Check
All four checks: No (one Elm page + Main.elm routing wire-up; no backend change).

## Wiring
Router wiring: n/a server-side; includes SPA wiring (`Main.elm` handling of the new OutMsg) — user-facing on completion.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.5.1 (result-click slice) | (1) result renders as `<button class="search-result" id="search-result-<bookId>">` with `onClick (BookClicked book.id)` — `Page/Search.elm:399-411`; (2) `BookClicked` → `OpenOverlay bookId` OutMsg — `Page/Search.elm:201-202`; (3) `Main.SearchMsg` handles `Search.OpenOverlay` → `openOverlayWithTrigger baseModel bookId ("search-result-" ++ bookId)` — `Main.elm:1572-1583`; (4) overlay opens over `/search`, URL unchanged, trigger id stored for focus-return — `Main.elm:2372-2398` (`openOverlayWithTrigger`) composing with #114 `triggerSpineId` focus-return `Main.elm:2085-2096` | Live on :4000 (2026-07-24): typed "Book", title-sorted, clicked "The Book of Laughter and Forgetting" → `book-overlay` visible showing that title; `page.url()` unchanged (`/search`); Escape closed overlay and focus returned to `#search-result-<bookId>`. `search.spec.ts` 14/14 green under `--project=chromium`. | ✅ | Built end-to-end + observed live |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- `Page.Search`: make each result an accessible interactive element (button semantics or anchor — keyboard focusable, role/aria correct), emit a new OutMsg (e.g. `NavigateTo (BookDetail bookId)` or the overlay-open pattern used by shelf spines — check how `Main.elm` opens the overlay from bookshelf pages and reuse that mechanism, per ADR-005 the overlay is UI state with `Route.BookDetail` coexisting for deep links).
- `Main.elm`: handle the OutMsg → open the overlay over `/search` (URL behaviour must match the overlay convention: overlay does not change the URL).
- Focus behaviour must compose with #114's focus-return work (trigger = the clicked result).
- Tests: program test for click → OutMsg; E2E in `search.spec.ts` — click a seeded result → overlay opens showing that book's title (extends #115's deterministic suite).

## Reviewer Context
- `searchResponseJson` in SearchProgramTest is the single object-shaped response builder — extend it, don't add bare-list bodies (the #115 revision-2 lesson).
- Elm exposing gotcha: land new exposed Msg/OutMsg constructors together with consuming tests.

## Test Audit

_Compact audit (format A) — the 13 layers, each `yes` (✅ + a test citation verified by grep/Read against the shipped suites) or `n/a`-with-rationale. This is a client-side slice: search results become accessible `<button>`s emitting an `OpenOverlay` OutMsg that `Main.elm` turns into an overlay over `/search`, reusing #114's focus-return. No backend change — the overlay reuses the existing `GET /api/books/:id` (validated under #114)._

Last generated: 2026-07-25 (post-implementation compact audit)

Legend: ✅ = real coverage | n/a = not applicable (one-line reason).

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1. API calls | no | n/a — no backend change; the overlay reuses the existing `GET /api/books/:id` (validated under #114). |
| 2. Auth & middleware guards | no | n/a — no new guard; overlay open is client-side SPA state. |
| 3. Database interactions | no | n/a — no DB interaction added. |
| 4. Event flow & lifecycle | no | n/a — opening the overlay emits no events. |
| 5. Background jobs (Oban) | no | n/a — no job. |
| 6. External service calls | no | n/a — no external call. |
| 7. Storage | no | n/a — no storage operation. |
| 8. Cache | no | n/a — no cache interaction. |
| 9. dbt models | no | n/a — no persisted data or dbt model. |
| 10. Elm frontend state machine | yes | ✅ `SearchProgramTest.elm:496` (`BookClicked` emits `OpenOverlay` for that book id), `:515` (a result renders as a `<button>` with id `search-result-<bookId>`); wire `Main.elm:1577` (`SearchMsg` handles `Search.OpenOverlay`) → `:1583`/`:2447` `openOverlayWithTrigger` composing with #114's `triggerSpineId` focus-return; E2E `search.spec.ts:312` (clicking a result opens the book detail overlay, URL unchanged, Escape returns focus — live). |
| 11. Operational metrics | no | n/a — SLO gate (`scripts/check-slo-gate.sh`). |
| 12. Performance & usability | no | n/a — SLO gate. |
| 13. Cost tracking | no | n/a — client-side navigation; no external spend. |

Tally: 1 ✅ / 12 n/a — 0 ❌, 0 ⚠️. GREEN.

## Definition of Done
- [x] Clicking (and keyboard-activating) a search result opens the book detail overlay for that book — evidence: `resultClickEmitsOpenOverlay` + `resultRendersAsButtonWithStableId` program tests (`SearchProgramTest.elm`, failing-first captured: `NoOut`≠`OpenOverlay`, no `<button>` found), native `<button>` = keyboard-activatable, + `search.spec.ts` "clicking a result…" live-drive on :4000 (overlay opens showing the title)
- [x] URL unchanged on overlay open (overlay convention) — evidence: `search.spec.ts` asserts `page.url()` unchanged and `pathname === "/search"` after click (live green)
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — US-1.5.1 result-click slice built end-to-end + observed live
- [x] Every behaviour has a validation path — click→OutMsg (program test, direct-update contract), button/stable-id render (program test view), click→overlay+URL+focus-return (E2E live)
- [x] Tests written and passing (`elm-test`, Playwright) — full `npx elm-test` **1031 passed, 0 failures** (includes SearchProgramTest 22/22 with the two new #289 tests; unblocked once #287 landed the `UploadTest.elm` `hasUserWriting` fix, cf88d4da); `search.spec.ts` 14/14 live on :4000.
- [x] Standards compliance verified — elm-format `--validate` clean, elm-review clean (src/ tests/), full elm-test green, vacuous-guard check clean (full `just verify` = auditor's remaining integration gate)
- [x] **Test audit is GREEN** — compact audit generated + citations verified 2026-07-25 (this section).
- [ ] **`completion-audit` skill passed on the integrated branch**
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`)

## Dependencies
- Issue #115 (deterministic search E2E harness — merged on feat/115-114-3-e2e)
- Issue #114's focus-return implementation (compose, don't conflict)

## Agent Assignment
`elm-agent`.

## Progress Notes
- 2026-07-23 — Created during #115 Phase 3: result-click affordance found unbuilt (plain div, no OutMsg); de-scoped from #115 per scope-lock.
- 2026-07-24 — Implemented (elm-agent). `Page.Search`: each result now a real `<button class="search-result" id="search-result-<bookId>">` (mirrors the shelf-spine `viewClickableSpine` pattern; native-keyboard-operable) emitting new `Msg BookClicked String` → new `OutMsg OpenOverlay String`. `Main.elm`: added `openOverlayWithTrigger` (refactored `openOverlay` to delegate) so the search list reuses #114's `triggerSpineId` focus-return with its own `search-result-<bookId>` trigger; `SearchMsg` now handles `Search.OpenOverlay`. CSS: reset native button chrome on `.search-result` (+`:focus-visible` amber outline) so the button renders as the card row. Tests test-first: `resultClickEmitsOpenOverlay` (direct-update contract, OutMsg swallowed by harness) + `resultRendersAsButtonWithStableId` (view: `<button>` + stable id) — failing-first captured against reverted impl (`NoOut`≠`OpenOverlay`; no matching `<button>`). E2E: `search.spec.ts` click-through test (title-sort → click → overlay shows title, URL unchanged `/search`, Escape → focus returns to row). Gates: SearchProgramTest 22/22 isolated; `search.spec.ts` 14/14 live on :4000; elm-format/elm-review clean; vacuous-guard check clean. Full `npx elm-test` blocked from compiling by unrelated in-flight #287 edit (`UploadTest.elm:68` missing `hasUserWriting`) — reported to impl-287-resume.
