# Issue #293: Fix placement_history Factory FK Defaults

## Summary
`placement_history_factory` defaults `book_id`, `from_bookshelf`, and `to_bookshelf` to random `Ecto.UUID.generate()` values, so a standalone `insert(:placement_history)` violates three foreign keys (`book_id` is `null: false references(:books)`; `from`/`to_bookshelf` reference `:bookshelves` — migration 20260305000007). Every caller must override all three (as #113's `seed_move_history/3` had to). Fix the factory so a bare insert succeeds.

## User Stories
None — test-infrastructure hygiene. Validation: a bare `insert(:placement_history)` succeeds; existing suites stay green.

## Goal
The next test author can `insert(:placement_history)` without hitting an FK wall.

## Scope Check
All four checks: No (one factory function + a smoke test).

## Wiring
Router wiring: n/a — test infrastructure only.

## Feature-Completeness Pre-Check
n/a — no user stories (test infra).

## Technical Requirements
- In `apps/core/test/support/factory.ex`: `placement_history_factory` → `book: build(:book)` (valid FK by association) and `from_bookshelf: nil, to_bookshelf: nil` (columns are nullable); callers needing specific bookshelves keep overriding.
- Add a minimal test proving `insert(:placement_history)` succeeds bare.
- Sweep existing callers: none should rely on the random-UUID defaults (they all override today — verify with grep).

## Reviewer Context
- Recommended by #113's elixir review (2026-07-24). `Shelving.spine_data/1` move_count counts history by `book_id` — factory changes must not alter that key's semantics.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 3 (DB/test-infra) | yes | ❌ bare-insert smoke test needed → ✅ when done |
| others | no | n/a — factory-only change |

## Definition of Done
- [ ] Bare `insert(:placement_history)` succeeds — evidence: new smoke test green
- [ ] All existing suites green (`just run mix test`) — evidence: run output
- [ ] `just verify` passes; **`completion-audit` passed**

## Dependencies
None.

## Agent Assignment
`elixir-agent`.

## Progress Notes
- 2026-07-24 — Created from #113 elixir-review P3 advisory (three-FK wall on bare insert, empirically hit during #113 Phase 1).
