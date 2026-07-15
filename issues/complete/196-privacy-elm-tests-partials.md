# Issue #196: Privacy — Elm Tests + Partial-Story Builds

**Epic:** #122 (E2E Test Suite — Privacy & Visibility) · integration branch `feat/122-e2e`

## Summary
Add Elm state-machine tests for the built/partial privacy frontend (stories US-10.1.1 / US-10.2.1 / US-10.2.3 / US-10.3.1 / US-10.4.1), plus three small in-scope BUILDS that make the partial stories genuinely test-ready. The builds must precede their tests.

## User Stories
US-10.1.1, US-10.2.1, US-10.2.3, US-10.3.1, US-10.4.1 — frontend (built/partial surface; three small render gaps closed here).

## Wiring
- [x] This issue includes router/UI wiring and is user-facing when complete (small render builds).
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
The five stories' frontends are already built; three have small render gaps (below) closed in-scope here so they become test-ready. No new stories claimed beyond finishing these partials.

| User Story | Gap | Verdict | Resolution |
|-----------|-----|---------|------------|
| US-10.2.1 — Shelf Visibility | shelf save-confirmation render missing | 🟡 partial | build (a) here |
| US-10.4.1 — Search Engine Privacy | info text absent | 🟡 partial | build (b) here |
| US-10.3.1 — ViewAs | banner shows raw perspective | 🟡 partial | build (c) here |
| US-10.1.1 — Profile Visibility | built; test-only | ✅ | tests here |
| US-10.2.3 — Blog Post Visibility | built; test-only | ✅ | tests here |

Verdict: 🟡 partials built in-scope → ✅; others test-only. Driven live at DoD.

## Technical Requirements
**Tests (punch #7, #8, #11, #12):**
- **#7** `Page.Settings.Privacy` profile: init, `SetProfileVisibility`, `SaveProfileVisibility` Ok/Err.
- **#8** Privacy shelf rows: `SetShelfVisibility`, `SaveShelfVisibility` Ok/Err.
- **#11** `Page.Blog.Editor`: `SetVisibility` parse, `SaveDraft`/`Publish` Ok/Err.
- **#12** `Components.ViewAsBar`: banner render, `getViewAs`, `removeViewAs`.

**Small BUILDS (must precede their tests):**
- (a) Render shelf save-confirmation / "Saved!" + error feedback in `frontend/src/Page/Settings/Privacy.elm` (model tracks `savingShelf` at ~:22 but the view never shows it) — US-10.2.1 §1.
- (b) Add the "…will never appear in search engine results" informational text to `Page/Settings/Privacy.elm` (US-10.4.1 §1 — currently absent).
- (c) Map the ViewAs banner label so `unauthenticated` renders `"Viewing as: Not logged in"` in `frontend/src/Components/ViewAsBar.elm:14` (currently shows the raw perspective).

## Reviewer Context
- Msg types for tested pages must expose `Msg(..)` so tests can construct them.
- All Elm API calls use `RemoteData` (NotAsked / Loading / Success / Failure).

## Definition of Done
- [ ] Builds (a), (b), (c) implemented — the three partial stories become test-ready.
- [ ] Elm state-machine tests for punch #7, #8, #11, #12 written and passing.
- [ ] `just verify` passes.
- [ ] **Feature-Completeness Pre-Check ✅** — the three partials built end-to-end and driven live on a preview.
- [ ] The #122 audit cells for punch #7/#8/#11/#12 go GREEN.

## Dependencies
Epic #122. The five Elm modules already exist (`Page.Settings.Privacy`, `Page.Blog.Editor`, `Components.ViewAsBar`). Soft-feeds E2E child #198 (selectors/built partials).

## Agent Assignment
elm-agent.

## Progress Notes
- 2026-07-14: Created as child of #122 epic (feat/122-e2e).
