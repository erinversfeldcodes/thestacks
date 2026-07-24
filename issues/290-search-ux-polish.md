# Issue #290: Search UX Polish — Sort Semantics, Filter Affordances, Copy Tone

## Summary
Bundle of advisory UX findings from #115's review (2026-07-24, ux-reviewer + elm-reviewer, all P2/P3): (a) the "Date Added" sort option is a silent no-op on platform-wide results (no per-user timestamp exists) and relevance order is discarded by the ByTitle default; (b) books with no publication year silently vanish when any year bound is set, and the filtered-empty state shows the misleading "No books found matching your search."; (c) search copy is functional but off the dark-academic register. All three pin against #115's AC strings/option list, so they are AC-level changes — hence a tracked issue, not silent divergence.

## User Stories
- US-1.5.1 — Search Across Shelves (polish slice; behaviour shipped in #115)

## Goal
Search controls are truthful (no dead options), filter behaviour is legible (undated books don't vanish unexplained), and copy matches the platform's voice — with the US/AC and E2E assertions updated in lockstep.

## Scope Check
All four checks: No (one Elm page + components + copy/AC/E2E string updates).

## Wiring
Router wiring: n/a — polish of existing UI; user-facing on completion.

## Feature-Completeness Pre-Check
n/a-adjacent — polish of a shipped story; fill hops for the changed affordances when picked up.

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.5.1 (polish slice) | ⬜ to verify | ⬜ to verify | ⬜ | — |

## Technical Requirements
- **Sort semantics** (decide one): hide "Date Added" (SortSelector.elm:26) until search is collection-scoped; or rename it "Relevance" (it preserves backend plainto_tsquery order — truthful); consider making Relevance the default over ByTitle (users expect relevance-ranked search). Update US-1.5.1 AC + `e2e/tests/search.spec.ts` sort assertions in lockstep.
- **Undated books under year filter**: keep-with-"unknown year" affordance or an "include undated" toggle (today `bookWithinYearRange` returns False for Nothing — Search.elm:325-327). Filter-aware empty message when the filter (not the query) empties results (Search.elm:234-235).
- **Copy warm-pass** (hint/empty/error/loading strings in Page.Search + readers-section error at :259) per ux-review suggestions; AC + E2E string assertions updated together.
- Minor: SortSelector renders no `selected` attr from `current` (uncontrolled dropdown — desyncs if sort set programmatically); stringly-typed `SortChanged String` could emit `SortOrder` directly (pre-existing component contract).

## Reviewer Context
- search.spec.ts asserts exact copy strings and the sort option set — every string change here must update spec + US in the same diff.
- List.sortBy is stable; "Relevance"=passthrough relies on backend order stability.

## Test Audit
[Baseline via `test-audit` skill when picked up.]

## Definition of Done
- [ ] Sort option set is truthful (no silent no-op) and default decided — evidence: elm-test + E2E + US updated
- [ ] Undated-book filter behaviour legible + filter-aware empty state — evidence: elm-test + E2E
- [ ] Copy pass applied with AC/spec lockstep — evidence: diff spans US + specs + view
- [ ] Tests written and passing; `just verify` passes
- [ ] **`completion-audit` passed**; **Completion Bar met**

## Dependencies
- #115 (shipped behaviour this polishes), #285 (collection scoping would give "Date Added" real semantics — coordinate)

## Agent Assignment
`elm-agent` + `ux-reviewer` advisory.

## Progress Notes
- 2026-07-24 — Created from #115 review advisories (ux P2 ×2, P3 ×2; elm-reviewer relevance-default note).
