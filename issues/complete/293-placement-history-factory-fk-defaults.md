# Issue #293: Fix placement_history Factory FK Defaults

## Status: CLOSED — correct-by-design, resolved by documentation (2026-07-24)

The premise ("fix the factory so a bare insert succeeds") turned out to be un-implementable as a factory-only change, and the current behaviour is correct by design. Resolution: document the FK contract at the point of failure rather than change behaviour. See the three-contract analysis in Progress Notes.

## Summary
`placement_history_factory` defaults `book_id`, `from_bookshelf`, and `to_bookshelf` to random `Ecto.UUID.generate()` values, so a standalone `insert(:placement_history)` violates three foreign keys (`book_id` is `null: false references(:books)`; `from`/`to_bookshelf` reference `:bookshelves` — migration 20260305000007). Every caller must override all three (as #113's `seed_move_history/3` had to).

**Resolution:** the factory is NOT changed. `op.bookshelf_placement_history` is an append-only audit trail deliberately decoupled from Ecto associations (`proto/persisted.exs:525-542` maps the three columns as plain `:binary_id`, never `belongs_to`, so a book/bookshelf delete never cascades its history away). Without an association ExMachina cannot lazily insert real FK targets on `insert`, and making it eager-insert breaks `build/1` (DB-free, all-fields-non-nil) which `factory_proto_validation_test` enforces. The three contracts (real-FK migration · build-is-DB-free-and-non-nil · no-association-by-design) cannot all hold for a bare-insertable factory. So the factory keeps its random-UUID defaults and gains a doc comment explaining the deliberate FK wall and the override pattern.

## Goal
The next test author who reaches for `insert(:placement_history)` understands — at the factory, before hitting a cryptic FK error — that they must override the FK fields with real rows (the `seed_move_history/3` pattern). Served by documentation, not by a behaviour change.

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
| 3 (DB/test-infra) | yes | ✅ no new test — a bare-insert smoke test would assert a BY-DESIGN FK failure; the factory's random-UUID FK contract is instead documented at the source. Existing coverage (`seed_move_history/3` in `shelving_test.exs`, proto-field coverage in `factory_proto_validation_test.exs`) stays green (145/145). |
| others | no | n/a — comment-only change |

## Definition of Done
Reframed to the documentation outcome (the "bare insert succeeds" goal is un-implementable — see Progress Notes):
- [x] FK contract documented at the point of failure — evidence: doc comment on `placement_history_factory` at `apps/core/test/support/factory.ex:134-152` states the three FKs default to random UUIDs by design (append-only audit table, no `belongs_to` per `proto/persisted.exs:525-542`), that a bare insert violates them intentionally, and shows the `seed_move_history/3` override pattern.
- [x] Zero behaviour change → all suites stay green — evidence: `just run mix test apps/core/test/stacks/shelving_test.exs apps/core/test/stacks/factory_proto_validation_test.exs` = `145 tests, 0 failures`; factory + shelving_test reverted byte-identical before the comment-only edit (`git status` clean pre-edit).
- [x] Analysis recorded so the decision isn't re-litigated — evidence: three-contract analysis in Progress Notes below; the `insert(:book).id` attempt was empirically shown to break `factory_proto_validation_test.exs:112` (`DBConnection.OwnershipError`), and `book: build(:book)` is impossible (no `:book` association → KeyError).

## Dependencies
None.

## Agent Assignment
`elixir-agent`.

## Progress Notes
- 2026-07-24 — Created from #113 elixir-review P3 advisory (three-FK wall on bare insert, empirically hit during #113 Phase 1).
- 2026-07-24 — Investigated; **closed as correct-by-design, resolved by documentation** (owner decision, Option A). The "fix the factory so a bare insert succeeds" premise is un-implementable because three contracts collide:
  1. **Migration `20260305000007`** puts real DB FKs on all three columns (`book_id` `null: false references(:books)`; `from_bookshelf`/`to_bookshelf` nullable `references(:bookshelves)`), so a bare insert needs a real book row + nil-or-real bookshelf rows.
  2. **`factory_proto_validation_test`** requires every persisted field non-nil in `build/1`, and (ExMachina convention) `build` must not touch the DB.
  3. **No `belongs_to` — by design.** `proto/persisted.exs:525-542` deliberately maps the three columns as plain `:binary_id`, because the history table is an append-only audit trail decoupled from op-schema lifecycle (a book/bookshelf delete must never cascade its history away).
  Without an association ExMachina can't lazily insert FK targets on `insert`. Empirical proofs: `book: build(:book)` (the ticket's literal suggestion) raises KeyError — there is no `:book` assoc on the struct; `book_id: insert(:book).id` makes bare insert valid (`shelving_test.exs` 107/107) but breaks `build`, failing `factory_proto_validation_test.exs:112` with `DBConnection.OwnershipError` (build ran a DB insert with no sandbox owner); `from_bookshelf: nil` violates proto-validation's non-nil rule. No factory-only edit satisfies all three at once. Adding `belongs_to` was rejected: it fights the documented audit-decoupling design and hits a codegen naming limitation (the bookshelf columns are `from_bookshelf`/`to_bookshelf`, not `*_id`). Resolution: keep the random-UUID defaults, add a doc comment at the factory explaining the deliberate FK wall + the `seed_move_history/3` override pattern. Zero behaviour change; suites 145/145 green.
