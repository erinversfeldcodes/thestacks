# Issue #286: Wire or Remove Books.search_platform/2 Dead Code

## Summary
`Stacks.Books.search_platform/2` (`apps/core/lib/stacks/books.ex:786`) has zero callers in `apps/core/lib` — it was added with tests but never wired to a controller. It also `ilike`-scans all books with no visibility filtering and no placement/bookshelf join, so wiring it as-is would leak non-platform books. Decide: remove it (and its 3 near-vacuous tests), or fix + wire it as the backing query for #285.

## User Stories
None directly — code-hygiene/security-adjacent cleanup. Validation path: compile + test suite green after removal, or #285's coverage if wired.

## Goal
No unwired, visibility-unsafe search query sits in the codebase; either the function backs a real endpoint with proper scoping, or it is gone.

## Scope Check
All four checks: No (single-function cleanup).

## Wiring
Router wiring: n/a — implementation-only cleanup (or wired by #285 if the "fix + wire" fork is chosen).

## Feature-Completeness Pre-Check
n/a — no user stories (code hygiene). If the "wire" fork is chosen, the story surface belongs to #285.

## Technical Requirements
- Fork A (remove): delete `search_platform/2` + its `books_test.exs` describe (3 tests at line ~573 that only assert `is_list`/`is_integer`/`count >= 0` — near-vacuous). Grep for any remaining reference.
- Fork B (fix + wire, only if #285 proceeds soon): rewrite on `plainto_tsquery`/`title_tsv` for parity with `search_books/2`, add placement/bookshelf visibility scoping, wire from `SearchController`/`CatalogueController`, and replace the vacuous tests with assertions that the matched book IS returned and excluded books are NOT.
- Note: the existing tests insert a `platform`-visibility bookshelf + placement fixture that the function never reads — the fixture is inert (verified 2026-07-23).

## Reviewer Context
- `search_books/2` applies visibility in the CONTROLLER (`Visibility.can_view?` in search_controller.ex:16), not in the context — parity matters whichever fork is chosen.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 3 (DB) | yes | ❌ removal leaves no gap (function deleted) OR wired query gains real match/exclusion assertions |
| 1–13 (others) | no | n/a — single-function cleanup; app surface unchanged (Fork A) or covered under #285 (Fork B) |

## Definition of Done
- [ ] Fork chosen and executed (remove, or fix+wire under #285) — evidence: diff + grep showing no unwired references
- [ ] Near-vacuous tests removed or replaced with real match/exclusion assertions — evidence: test file diff
- [ ] Tests written and passing (`mix test`)
- [ ] Standards compliance verified (`just verify` passes)
- [ ] **`completion-audit` skill passed on the integrated branch**
- [ ] **Meets the Completion Bar** — n/a-heavy (no user-facing deliverable in Fork A); cite suite-green evidence

## Dependencies
- #285 (Fork B only)

## Agent Assignment
`elixir-agent`.

## Progress Notes
- 2026-07-23 — Created at #115/#114/#113 epic kickoff from the #115 re-verification finding (unwired + unscoped + vacuous tests).
