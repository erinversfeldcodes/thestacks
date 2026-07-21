# Issue #271: Expose `ReadingPile.Msg(..)` and `Main.transitionClass` for Test Access

## Summary
Three Issue #112 punch items (#7 ReadingPile happy path, #8 ReadingPile sad path, #9 `transitionClass`
unit test) are **unwritable** as the code stands: `Page.Bookshelf.ReadingPile` exposes an opaque `Msg`,
and `transitionClass` is absent from `Main.elm`'s exposing list. This issue makes both testable. It is
a small **production** change, which is why it is tracked separately rather than absorbed into #112 —
#112's Scope Check claims "test files only".

## User Stories
None directly. Unblocks validation of US-1.2.4 (Browse the Reading Pile) and US-1.2.5 (Shelf
Transitions) in #112.

## Goal
`ReadingPile.Msg` constructors and `transitionClass` are reachable from `frontend/tests/`, with no
behavioural change to the application and no widening of the public surface beyond what tests require.

## Scope Check
- Does this issue touch more than 3 controllers? No — no Elixir.
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No — two exposing-list changes.
- Does this issue combine unrelated concerns? Borderline: two modules, one shared purpose
  (unblock #112's Elm layer). Kept together deliberately — splitting a two-line change is waste.

## Wiring
Router wiring: implementation-only (module exposing lists; no user-facing surface). Consumed by
#112 punch items #7, #8, #9.

## Feature-Completeness Pre-Check
n/a — no user stories. This is a test-surface enabling change; it builds no user-facing behaviour.

## Technical Requirements
- `frontend/src/Page/Bookshelf/ReadingPile.elm:3` currently exposes `Msg` (opaque). Change to `Msg(..)`.
  Compare `frontend/src/Page/Bookshelf.elm:4`, which already exposes `Msg(..)` — this is the
  established project convention for pages that have tests.
  Constructors to become reachable: `BooksLoaded (Result Http.Error (List Shelf))`, `DismissAgeGate`,
  `BookHovered String`, `BookClicked Book`, `Deselect`.
- `transitionClass : Route -> Route -> String` (`frontend/src/Main.elm:2355-2365`) is not in `Main`'s
  exposing list. Expose it, **or** — preferred if it is clean — extract it into a small dedicated
  module (e.g. `Animation/Transition.elm`) that both `Main` and the tests import. Extraction avoids
  widening `Main`'s public surface; the implementer should choose and justify.
- **No behavioural change.** This is surface-only. Any diff touching update/view logic is out of scope.
- `elm-review` must stay clean: an exposed-but-unused export can trip the "no unused exports" rule
  until the consuming test lands. If `elm-review` objects, land the enabling change together with at
  least one consuming test rather than adding a suppression.

## Reviewer Context
- Project memory records that `elm-review --fix` has previously **damaged** exposing lists, and that
  `Msg(..)` exposure for tested pages had to be restored by hand. Verify `elm-review` does not revert
  this change.
- `Page.Bookshelf` (unified) and `ReadingPile` are **different** modules with different Msg shapes:
  unified uses `ShelvesLoaded`/`shelves`; ReadingPile genuinely uses `BooksLoaded`/`books`. Do not
  "harmonise" them.

## Test Audit
Compact format — enabling change, no user-story surface.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine (L10) | yes | ✅ — `tests/Page/ReadingPileMsgTest.elm` (9 tests) drives every `Msg` constructor through `update`; `tests/Animation/TransitionTest.elm` (5 tests) covers all three `transitionClass` branches. Both compile against the newly-reachable surface. |
| Build / lint | yes | ✅ — `elm-review` and `elm-format` clean after the change; `elm make --optimize` builds with no warnings |
| 1–9, 11–13 | no | n/a — no API, DB, event, job, storage, cache, dbt, metric or cost surface touched |

## Definition of Done
- [x] `ReadingPile.Msg(..)` reachable from `frontend/tests/` — evidence: a test importing a constructor, compiling
- [x] `transitionClass` reachable from `frontend/tests/` (exposed or extracted; choice justified) — evidence: a test importing it, compiling
- [x] No behavioural change — evidence: diff contains only exposing/extraction changes
- [x] `elm-review` clean, and does not revert the exposing change — evidence: `npx elm-review --config elm-review src/ tests/` → output
- [x] `elm-test` suite green — evidence: command → pass count
- [ ] `just verify` passes — **BLOCKED (environmental, not this change).** `just verify` cannot run in a
  fresh worktree: it fails at its first recipe, `lint-elixir`, because `apps/core/lib/stacks/gen/`
  (~16 generated Ecto schemas) is gitignored and absent, so the umbrella will not compile —
  `Stacks.Accounts.User.__struct__/1 is undefined` and ~20 similar. `mix proto.sync`, the task that
  generates them, is itself an umbrella mix task and so cannot bootstrap: it fails with the same
  compile errors. Only `just setup` (full `setup.sh`, incl. local Postgres roles) resolves this.
  The diff is Elm-only, so the two verify slices it can affect were run directly and both pass:
  `scripts/lint-elm.sh` → `I found no errors!`, `scripts/test-elm.sh` → 878 passed / 0 failed.
  **Needs a re-run of `just verify` in the main checkout before merge.**

## Dependencies
None. Blocks #112 punch items #7, #8, #9 (Phase 3).

## Agent Assignment
`elm-agent`. Reviewer: `elm-reviewer`.

## Progress Notes

**2026-07-21 — elm-agent — implemented.**

- `Page.Bookshelf.ReadingPile` now exposes `Msg(..)` (`frontend/src/Page/Bookshelf/ReadingPile.elm:3`).
- `transitionClass` **extracted** (not exposed from `Main`) into `frontend/src/Animation/Transition.elm`.
  Body moved verbatim; `Main` now imports it (`frontend/src/Main.elm:20`) and the call site
  (`Main.elm:1208`) is unchanged. Main's now-unused `Animation.RoomTransition` /
  `Animation.SlideTransition` imports were dropped — they had no other use, and leaving them would
  have tripped `NoUnused.Variables`. Rationale for extraction over exposing from `Main`: it keeps
  `Main`'s public surface unwidened, puts the function in the `Animation/` namespace it already
  belonged to, and — unlike an export from `Main` — leaves it with a real in-app consumer, so its
  export does not depend on a test existing in order to survive `elm-review --fix`.
- Consuming tests landed (test-first; both verified failing before the source change — `MODULE NOT
  FOUND: Animation.Transition` and `NAMING ERROR: I cannot find a BooksLoaded variant`):
  `frontend/tests/Page/ReadingPileMsgTest.elm` (9 tests, drives every `Msg` constructor through
  `update`) and `frontend/tests/Animation/TransitionTest.elm` (5 tests, all three branches).
- **`elm-review` revert hazard verified, not assumed.** With both test files temporarily moved aside,
  `NoUnused.Exports` reports `(fix) The constructors for type Msg are never used outside` on
  `ReadingPile.elm:3` — i.e. `--fix` *would* narrow `Msg(..)` back to `Msg`. With the tests present,
  `elm-review --config elm-review src/ tests/` → `I found no errors!`. No suppression added.
- Gates: `elm-test` 878 passed / 0 failed (864 baseline + 14 new); `scripts/lint-elm.sh` clean;
  `elm-format --validate src/ tests/` clean; `elm make src/Main.elm --optimize` builds with no warnings.
- No behavioural change: `git diff` on `src/` is one exposing-list line plus a verbatim function move.

Ready for `elm-reviewer`. Unblocks #112 punch #7/#8/#9.
