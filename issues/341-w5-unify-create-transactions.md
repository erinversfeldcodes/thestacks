# Issue #341: W5 child — One create transaction, and stop discarding resolved metadata

## Summary
Child of epic #315, Level 1. `Books.create/1` (`books.ex:175-227`) and `Books.create_confirmed_book/4` (`books.ex:1019-1070`) are two independent implementations of "make a work and its first edition". They have drifted: the confirmed path drops `google_books_id`, and `merge_edition/2` (`books.ex:1085`) discards the resolved metadata it was just handed. Collapsing them is the precondition for wiring `confirm/2` into the manual path (#343) — otherwise wiring the verb spreads the drift instead of removing it.

## User Stories
US-1.1.5 (manual entry), US-1.1.8 (same-work merge).

## Goal
There is exactly one transaction that creates a work + edition. Every caller reaches it. Resolved metadata that the system paid an external API call for is never silently dropped.

## Scope Check
One context module, two functions collapsed into one, plus their call sites. No new endpoints. Under the bar.

## Wiring
Router wiring: none — internal. Becomes user-visible through #343.

## Feature-Completeness Pre-Check
n/a at this level — no new story surface; #343 and #344 consume this.

## Technical Requirements
1. **Collapse `create/1` and `create_confirmed_book/4` into one transaction.** Keep the ISBN hard gate and the `book.created` event emission on the single path. Every field either path set must still be set — enumerate them before you start and assert the union in a test, or the collapse will quietly lose one the way `google_books_id` was already lost.
2. **Restore `google_books_id`** on the confirmed path. Prove it with a test that fails against today's code first.
3. **`merge_edition/2` keeps its resolved metadata** rather than discarding it (`books.ex:1085`). Decide explicitly what happens on conflict — incoming wins, existing wins, or fill-only-if-null — and say why in a comment. "Fill only if null" is the conservative default: it cannot destroy data a reader or an earlier resolve already established.
4. **`verification_source` (from #335) must be set correctly on the unified path.** It is now NOT NULL with a CHECK — a create path that guesses will fail at the database. The mapping already exists as `Books.verification_source_from/1`; use it rather than re-deriving.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w5-315` FIRST — LOCAL, UNPUSHED branch, do NOT `git fetch` or reference `origin/`. Copy `/Users/erinversfeld/thestacks/.env`. Regenerate proto artifacts (`bash scripts/gen-ecto-proto.sh && bash scripts/gen-elixir-proto.sh`); if `core` won't compile because `apps/core/lib/stacks/gen/` is missing, rsync it from the main checkout first, then regenerate and confirm `mix proto.sync --check` is clean. If `PageControllerTest` fails on a missing `priv/static/index.html`, copy `apps/core/assets/index.html` there.
- **NEVER run bare `mix`/`elixir`** — always `just run mix …`. **Wrap long runs in `caffeinate -i`.**
- **NEVER revert a probe with `git checkout`** — use Edit, verify with `grep -c`.
- Wave 4 landed underneath you: multi-shelf placements are legal (`get_placements_for_book/2` returns a LIST; the singular `get_placement_for_book/2` is GONE), `book_editions.verification_source` is NOT NULL + CHECK-constrained, and proto enums are closed types with a build-failing coverage gate (`scripts/check-enum-coverage.py`).
- ⚠️ `confirm/2` already branches on "is it on the bookshelf they asked for?" (#333) — do not regress that to "does any placement exist?", which was a silent no-op bug.
- Commit: agent commits are DENIED. Stage everything; ONE-LINE message (no body/trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-341.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB interactions | yes | ❌ field-union test: every field either old path set is set by the unified one (mutation-probe by dropping one) |
| API calls | yes | ❌ `google_books_id` present after a confirmed create — red against today's code |
| DB interactions | yes | ❌ `merge_edition/2` retains resolved metadata; conflict rule asserted |
| Others | no | n/a |

## Definition of Done
- [ ] One create transaction; both former entry points route to it — evidence: diff + `grep` showing no second implementation
- [ ] `google_books_id` regression test red-then-green — evidence: probe transcript
- [ ] `merge_edition/2` retention + stated conflict rule — evidence: test name + comment
- [ ] `verification_source` correct on the unified path — evidence: test asserting each provenance value
- [ ] Suites green under `caffeinate` — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #315. **Depends on #314** (verification_source, placement model). **Precedes #343** (wiring the verb must not spread the drift) and #345 (extraction moves this code). Level 1 — parallel with #342 (disjoint: context vs worker/vision).

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-31 (Wave 5 kickoff).
