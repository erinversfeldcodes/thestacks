# Issue #333: W4 child — The multi-shelf placement model (and the live 500 it causes)

## Summary
Child of epic #314 (Wave 4, staff-campaign-2026-07-30). **Owner ruling 2026-07-30:** the same book MAY sit on several bookshelves at once; two copies of the same ISBN on the *same* bookshelf stay forbidden; and when a book sits on 2+ of Library / Antilibrary / Reading Pile / Wish List the book detail must **highlight that** so the reader can remove the extras. The code currently assumes at most one placement per (user, book) and **raises** when there are two — verified live on 2026-07-30: `GET /api/books/:id` returned **500** for the owner of a double-placed book.

## User Stories
US-1.1.6 (duplicate awareness), US-1.3.1/US-1.4.1 (book detail), US-1.5.1 (search annotation), US-1.6.4 (remove).

## Goal
Multi-shelf placement is a first-class, legal state everywhere: no raise, the detail overlay surfaces it with per-placement remove, search names every shelf a book sits on, and both add-paths inform (never block) when the book is already in the collection.

## Scope Check
1 context function + 4 call sites + 2 Elm surfaces. No migration (the constraint already exists — see Wiring). Under the bar.

## Wiring
Router wiring: no new routes; book-detail and search behaviour changes are user-facing on completion.
**No migration needed.** `bookshelf_placements_book_active_idx` (`20260305000006_create_bookshelf_placements.exs:42`) is already `UNIQUE (book_id, bookshelf_id) WHERE removed_at IS NULL` — exactly the owner's "not twice on the same shelf" rule, enforced at rung 4. Do **not** widen it to (user, book): that would forbid the multi-shelf state the owner just made legal.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| Owner views a double-placed book | `book_controller.ex:276` → `get_placement_for_book/2` → `Repo.one()` | **500** (driven 2026-07-30) | ❌ | fix in-scope |
| Book detail shows multi-shelf presence | no such hop exists | book appeared on 2 shelves with no indication | ❌ | build in-scope |
| Search names all shelves | annotation shows one shelf | "On your Wish List shelf" while also on Reading Pile | 🟡 | fix in-scope |
| Manual-ISBN duplicate notice | photo path has `is_duplicate`; manual path has none | silent second placement | ❌ | build in-scope (informational) |

## Technical Requirements
1. **De-raise the lookup.** `Shelving.get_placement_for_book/2` (`shelving.ex:633-640`) ends in `Repo.one()` and its `@spec` promises `Placement.t() | nil` — with two active placements it raises `Ecto.MultipleResultsError`. Replace with a list-returning function (e.g. `get_placements_for_book/2 :: [Placement.t()]`), keeping a single-result helper only if a caller genuinely wants "any one". Update all four call sites, each on its own merits:
   - `book_controller.ex:276` — the live 500; the detail response must carry **all** placements.
   - `book_controller.ex:56` — the `confirm` 201 path.
   - `books.ex:1079` and `:1088` — `place_or_return_existing`-style branching on `nil | placement`.
   - `upload_controller.ex:285` — reject-identification cleanup (`%{id: placement_id} <- …`); decide deliberately which placement it should clean up when there are several, and say why.
2. **Book detail highlight.** When a book has active placements on **2 or more of** `library`, `antilibrary`, `reading_pile`, `wishlist` (Looking-for-a-Home is excluded per the ruling — it is a marketplace state, not a duplicate), the overlay names each shelf and offers a per-placement remove. Copy should be informational and in-voice, not an error — the reader chose this; we are just making it visible and fixable.
3. **Search annotation.** "Your Collection" results currently name a single shelf and silently collapse the rest — list them all.
4. **Manual-ISBN parity.** The photo path computes `is_duplicate` in the controller (`upload_controller.ex` SSE payload) and the client renders "Already in Your Library". The manual path has no such hop. Add the equivalent *informational* notice — it must **never block** the placement (owner ruling: inform, never block).

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w4-314` FIRST (worktrees share refs; branch is local/unpushed). Copy `/Users/erinversfeld/thestacks/.env`; `bash scripts/gen-ecto-proto.sh && bash scripts/gen-elixir-proto.sh`; copy `apps/core/assets/index.html` → `apps/core/priv/static/index.html` if PageControllerTest fails. elm-test via the MAIN checkout's binary with `proto/gen/elm` copied in.
- Long suite runs under `caffeinate -i` (this machine slept mid-run twice, producing phantom `ExUnit.TimeoutError`s).
- Factories are now honest (#329) — `insert(:placement)` derives its shelf from its bookshelf, so building a genuine two-shelf fixture means two bookshelves, one book. `factory_honesty_test.exs` shows the patterns.
- The duplicate state is *legal*, so tests must assert the UI/telemetry response to it, not its absence.
- SCOPE-LOCK: `verification_source`, `book_edition_id` and the FKs are #335's; proto enums are #334's.
- Commit: agent commits are DENIED. Stage everything, write a ONE-LINE message (no body, no trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-333.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB interactions | yes | ❌ two placements on two bookshelves = OK; second placement on the SAME bookshelf still rejected by the existing index |
| API | yes | ❌ owner GET /api/books/:id with 2 placements → 200 carrying both (the 500 repro, as a test) |
| Elm | yes | ❌ detail highlight renders for a 2-shelf book with per-placement remove; search annotation lists both; manual-path notice appears and does not block |
| Others | no | n/a at child level |

## Definition of Done
- [ ] `get_placement_for_book/2` can no longer raise; all 4 call sites updated with a stated decision each — evidence: diff + test names
- [ ] The 500 repro is a regression test and passes — evidence: test name + before/after status
- [ ] Multi-shelf highlight + per-placement remove driven live on preview — evidence: screenshots (epic-level drive)
- [ ] Search lists every shelf; manual-path notice informs without blocking — evidence: tests + drive
- [ ] Mutation probe on the 500 regression test (restore `Repo.one()` → must redden) — evidence: transcript
- [ ] Suites green under `caffeinate` — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #314. Level 1 — parallel with #334 (disjoint). **Precedes #335** (migrations touch the same table; settle behaviour first).

## Agent Assignment
elixir-agent + elm-agent.

## Progress Notes
Filed 2026-07-30 (Wave 4 kickoff approved). Owner ruling embedded: multi-shelf legal; same-shelf forbidden (existing index, do not widen); highlight on the four named bookshelves; inform never block.
Built in worktree; commit 29e40692; merged into `feat/campaign-w4-314`. 24 files, +1377/−85.
**staff-review verdict: LGTM** (2026-07-30, Mode B on 29e40692). Praise: (a) it **deleted the singular `get_placement_for_book/2` outright** rather than keeping a convenience variant — "a function that can carry only one answer is the shape that produced the bug" is the correct read, and leaving a singular helper would have let the defect regrow at the next call site; (b) it found a **second live defect the issue did not name**: `books.ex:1079` branched on "does any placement exist?", so confirming a wish-listed book onto your Library **silently did nothing and reported success** — a block dressed as a no-op, invisible because it returned `{:ok, …}`; (c) the `upload_controller.ex:285` decision (withdraw `List.last/1`, the newest placement only) reasons about the *reader's* intent — removing all placements would destroy ones the reader made deliberately to undo our mistake — and flags itself as a heuristic pending #335's `verification_source`; (d) `Enum.uniq_by` → group-by-book-id was chosen over `chunk_by` for a stated reason (equal-titled books' rows interleave under the `bs.name` tie-break), i.e. the unsafe-but-obvious version was considered and rejected; (e) `scripts/check-orphan-classes.sh` caught its 7 new classes and it added the rules — the memory-noted orphan-class discipline held without prompting; (f) it reported "no live drive — that is the epic-level step", correctly declining to claim the DoD box it did not earn.
**No migration, and that is the point.** `bookshelf_placements_book_active_idx` is untouched (`git diff W3..HEAD -- priv/repo/migrations` is empty), so the owner's "not twice on the same shelf" rule stays enforced at rung 4 while multi-shelf becomes legal above it. New test at `shelving_test.exs:793` asserts `Ecto.ConstraintError` on a same-bookshelf duplicate.
**Lead independent probe (beyond the child's 500 repro):** I probed the *discovered* defect rather than the specified one — reverted `Enum.find(placements, &(&1.bookshelf.name == shelf_name))` to `List.first(placements)`, the old "any placement counts" form. Red, with the exact silent-no-op signature: `test confirm/2 a book owned on another bookshelf is still placed on the requested one` — `left: {:ok, :existing, …}` / `right: {:ok, :already_placed, …}`. Restored via **Edit** (never `git checkout`); `git status` clean, `grep -c` → 1.
**Deviations accepted:** (1) three **additive** proto fields (`buf breaking` passes) — the scope-lock named *enums* as #334's, and new fields on response messages are this issue's own contract; (2) `Books.confirm/2` arity 4→5 with no SPA caller (`grep`-confirmed); (3) `search_controller_test.exs`'s `place/4` helper was silently dropping `:removed_at` through a `Keyword.take`, so a test asserting a removed placement's absence could have passed for the wrong reason — fixed in passing and worth noting as its own small test-truthfulness win.
Suites: elixir **3229/0** (15 properties, 9 excluded), elm **1344/0**; credo, `proto.sync --check`, all five codegen targets, `check-css.sh`, `check-orphan-classes.sh` (**0 unstyled**) clean.
