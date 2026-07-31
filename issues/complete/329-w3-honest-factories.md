# Issue #329: W3 child — Factories build only states production can produce

## Summary
Child of epic #313. `apps/core/test/support/factory.ex` (512 LOC) is `use ExMachina.Ecto` with **no `insert/2` override**: all 44 factories go struct → `Repo.insert!`, bypassing every changeset, context function and invariant. That is why the suite is full of states the real system cannot make — and why the duplicate-placement constraint gap was invisible until a live drive found it.

## User Stories
None directly — but this restores the *testability* of US-1.1.2 (ISBN gate), US-1.6.1/1.7.1 (placement/shelf integrity) and US-14.2.1 (confirmed-account lifecycle).

## Goal
An invalid state is unconstructable from the factory. Specifically: no editionless book, no checksum-invalid ISBN, no placement whose `shelf` belongs to a different bookshelf, no "confirmed" user that never traversed confirmation.

## Scope Check
Test support + the fallout it exposes. ⚠️ If fixing fallout requires **production** changes beyond a line or two, that is a scope surprise — stop and report, do not absorb it.

## Wiring
Router wiring: n/a.

## Feature-Completeness Pre-Check
n/a — no user stories built here.

## Technical Requirements
Fix these four factories first; they are the ones with proven consequences:
1. **`book_factory` (`:67-76`)** creates a work with zero editions — violating the ISBN hard gate (`books.ex:9`), which both real creation paths enforce inside one `Ecto.Multi`. Make the factory produce a book *with* its primary edition (via the context function or a changeset-backed insert). Anything depending on `Books.primary_edition/1` being non-nil is currently tested against a shape prod never produces.
2. **`book_edition_factory` (`:82-92`)** emits `sequence(:isbn, &"978074327#{pad(&1)}")` — ~90% checksum-invalid, while production validates on every write path (`books.ex:1213`). Generate valid ISBN-13s (compute the check digit). Also `is_primary: true` is hardcoded (`:89`), so two editions of one book are both primary — impossible in prod (`books.ex:1101` sets `false` on merge).
3. **`placement_factory` (`:109-123`)** builds `bookshelf: build(:bookshelf)` **and** `shelf: build(:shelf)`, and `shelf_factory` builds its *own* bookshelf — so every bare `insert(:placement)` has `placement.bookshelf_id ≠ placement.shelf.bookshelf_id`, plus two orphan bookshelves for two different users. Production derives the shelf from the bookshelf (`shelving.ex:329,341,427`), and `:418-421` documents that this exact desync makes a book "stay visible on the source and never on the destination". Derive it — `price_snapshot_factory (:394-410)` already shows the correct pattern and says why.
4. **`user_factory` (`:39-51`)** sets `email_confirmed: true` with no token, so no test using `insert(:user)` ever traverses register→confirm→login. Route confirmed users through the real transition (or an explicit, documented helper that calls `Accounts.mark_confirmed/1`), and keep the unconfirmed state reachable — it is the state every real signup passes through and the one `ExpiredUnverifiedAccountsJob` exists to reap.

Then: run the full suite and **fix the fallout by building valid state, never by re-admitting the invalid**. Two factories documented as producing invalid state (`placement_history_factory :134-153`, `transaction_factory :268-278`) may keep their behaviour if their comments still justify it — say which you kept and why.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w3-313` FIRST (worktrees share refs; branch is local/unpushed — it will already contain #327's steerable seams, which you need: building a book through the public API triggers ISBN resolution). Copy `.env`; `bash scripts/gen-ecto-proto.sh && bash scripts/gen-elixir-proto.sh`. All mix via `just run`, long runs under `caffeinate -i`.
- Expect substantial fallout — it is the deliverable, not an accident. Report the count of tests that reddened and how each was fixed (category-level is fine: "N tests assumed editionless books → now build the edition").
- `conn_case.ex:61-64` has no auth helper, which is why controller tests hand-roll divergent `auth_conn`s. Do NOT unify that here (scope) — note it if it obstructs you.
- Commit: agent commits are denied. Stage; write a ONE-LINE message (no body/trailers) to `.../scratchpad/commit-msg-329.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Fixture realism | yes | ❌ four probes: attempt to build each impossible state → fails or is unreachable (editionless book, invalid-checksum ISBN, desynced placement, unconfirmed-bypassing confirmed user) |
| Suite | yes | ❌ full elixir suite green after fallout repair, count cited |
| 1–13 | no | n/a |

## Definition of Done
- [x] Four factories corrected — evidence: commit 158d089f + 8 impossibility probes quoted in the build report (editionless=1 edition, 0/500 invalid ISBNs, second-primary UNCONSTRUCTABLE via existing partial index, desync=false both ways, confirmed-user token nil, unconfirmed reachable → :email_unconfirmed)
- [x] Fallout repaired by building valid state — evidence: 154 reddened across 5 categories, each repaired by constructing valid state (123 one-primary, 16 shelf-position, 8 belongs_to, 4 assertions only true under invalid fixtures, 3 compile)
- [x] Full suite green under `caffeinate` — evidence: 3,208 tests 0 failures (+14 = the new guard rails); credo strict clean
- [x] Zero lines of `lib/` changed across 154 repairs — evidence: build report scope-surprise section; no escalation needed
- [x] `staff-review` verdict recorded below — evidence: LGTM + independent guard-rail probe (2/14 red), Progress Notes

## Dependencies
Epic #313. **Depends on #327** (steerable seams — factories going through the public API need to steer ISBN resolution). Level 2. Blocks #330.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-30 (Wave 3 kickoff approved). First attempt stalled on the watchdog during investigation with a clean worktree (nothing lost); relaunched with its one finding carried forward (`RequireConfirmedEmail` is in the auth pipeline, so the fix is a properly-confirmed default plus a reachable unconfirmed trait — not flipping the default). Built in worktree; commit 158d089f; merged.
**staff-review verdict: LGTM** (2026-07-30, Mode B on 158d089f). The best structural work of the campaign. Praise: (a) it did not merely probe the four impossibilities, it **left 14 guard-rail tests in the suite** (`factory_honesty_test.exs`) — the guarantee is now maintained rather than demonstrated once, which is the Bug-Catching-Ladder move (rung 6 → a standing rung-4/6 hybrid); (b) **zero lines of `lib/` changed** across 154 reddened tests — the scope-surprise rule held under real pressure, and every repair built valid state rather than re-admitting the invalid; (c) the `:editionless_book` escape hatch is exactly right — the forbidden state stays *explicitly* constructible for the four commented tests that are *about* its absence (the ISBN gate; `primary_edition/1`'s documented nil fallback), so honesty did not cost coverage; (d) the ExMachina workaround (arity-1 factories + pre-generated ids + `Ecto.put_meta(state: :loaded)`) is a real solution to "derive one column from another without Ecto double-inserting the shared parent", and pre-generated ids convert any future accidental double-insert into a loud `*_pkey` error.
**Three findings worth carrying forward** — the second is the sharpest of the wave: (1) `book_editions_one_primary_per_book` already existed as a partial unique index, so two primaries was *already* DB-unconstructable — the old factory simply never reached it because its books had no editions; the main scope risk evaporated. (2) **`price_snapshot_factory` — the very factory my spec named as the correct exemplar — was itself committing the desync its own comment warns about**: naming one unsaved `Book` on two associations makes Ecto insert the work twice (no identity map), so `book_id != book_edition.book_id`. Invisible until books gained editions, then a hard failure. My spec cited a broken exemplar; the child caught it. (3) `transaction_factory`'s seller/listing-seller mismatch is now derived *before* `Marketplace.Transaction` gets a production write path.
**Reviewer independent probe**: regressed `book_factory` to editionless → `factory_honesty_test.exs` 14 tests, **2 failures**; restored via Edit → 14/0, `git diff --stat` clean. The guard rails are falsifiable, not decorative.
Kept-as-is reviewed and accepted: `placement_history_factory` (append-only audit table deliberately mapped as plain `:binary_id`, so the random-UUID default is the documented forcing function that makes callers pass real FKs).
Suite: **3,208 tests, 0 failures** under caffeinate (up from 3,194 — the +14 are the guard rails); credo strict clean; format clean.
