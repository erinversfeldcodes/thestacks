# Issue #378: The edition a reader actually scanned is never recorded — the shelf silently stores a different one

## Summary
Found by the #376 agent while deciding what un-merge should do with placements. It is the **root cause**
of that question, and a wiring gap in its own right.

A reader scans a specific ISBN. That ISBN identifies a specific **edition** — a particular printing,
binding, cover and page count. What gets stored on their shelf is a different edition:

```
Books.confirm/2 → find_existing/1        returns the WORK, not the edition that was scanned
Shelving.place_book/3 (shelving.ex:377)  writes primary_edition_id/1 (shelving.ex:1327,
                                          ordered `desc: is_primary`)
```

So `book_edition_id` on every placement names **the work's primary edition**, never the one the reader
held in their hands. Scan a non-primary ISBN — a paperback reissue, a different regional printing — and
the shelf records the primary instead, silently.

## How it surfaced
#376 had to decide what happens to placements when a wrongly merged edition is split back out. The
answer turned out to be *"they stay"*, and the reason is this defect:

- `Shelving.place_book/3` is one of only two writers of `book_edition_id`, and it always writes the
  primary.
- `Books.merge_edition/2` hardcodes `is_primary: false` on the losing edition.
- **Therefore no placement in the system has ever named a merged edition.** There is no row-level
  record of who acquired the split-out one.

Every disposition rule #376 considered guesses badly *because the evidence was never written down*:
"move all" relocates readers who own the original; "move those created after the merge" catches
everyone added in that window; "move those whose upload named the ISBN" reads evidence that 30-day
image retention deletes, and that the manual-ISBN path never writes at all.

⚠️ **So this issue is what makes a correct un-merge possible later.** #376's disposition is right given
the data that exists; it is not right in principle, and it cannot be improved until this is fixed.

## Why it matters on its own
- **The ISBN hard gate exists to pin identity**, and the platform then discards which edition was
  verified. A reader's 1987 paperback shows as the 2011 hardback, with its page count and cover.
- **Page count feeds spine thickness** (US-1.3.1) — the shelf renders the wrong book's physique.
- **Marketplace listings** are about a physical copy someone owns; edition matters there.
- It is invisible: nothing errors, and the book on screen is *a* correct book for that work.

## User Stories
US-1.1.x (identity), US-1.3.1 (spine thickness), US-2.x (placement).

## Scope Check
⚠️ **Investigate before scoping.** The fix may be one argument threaded through `confirm/2` →
`place_book/3`, or it may implicate the whole works/editions read path. Establish which before
committing to a size; if it is the latter, this becomes a parent and the first child is the write path.

## Technical Requirements
1. **Record the edition that was actually verified.** `find_existing/1` returns the work; the caller
   knows the ISBN it matched. Thread it, rather than re-deriving a primary downstream.
2. **Cover the manual-ISBN path too**, not just the scan path — the issue is the write, and both write.
3. **Decide what happens to existing rows and say so.** Every current placement names a primary that
   may or may not be what its reader owns. ⚠️ Do not silently backfill a guess. If the true edition is
   unrecoverable for historical rows — and per the above it usually is — say that plainly; #340's
   registered-correction machinery is the honest place for any repair that *is* possible.
4. **Prove it with a non-primary ISBN.** A test that scans the primary passes today. The load-bearing
   case is a work with two editions where the reader scans the non-primary one and the placement
   records *that*.

## Reviewer Context
- ⚠️ `Books.merge_edition/2`'s conflict rule is justified on **mass-assignment** grounds
  (`BookController.merge_format/2` passes raw params). Do not loosen it while threading an edition id.
- Read **#376**'s `unmerge_edition.ex` and its disposition reasoning first — it documents this defect's
  consequences precisely, and its correctness depends on this issue's current (broken) behaviour. ⚠️ If
  you fix this, #376's "placements stay" rule needs revisiting, and its test asserts that rule
  explicitly.
- Related: **#370** (every edition mislabelled `barcode_unverified`) touches the same table for a
  different reason; check for interaction before both land.
- `gdpr-review` applies — `bookshelf_placements` is user data.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elixir | yes | ❌ scanning a non-primary ISBN records THAT edition — probe by reverting to `primary_edition_id/1` |
| Elixir | yes | ❌ the manual-ISBN path writes the same edition the scan path does |
| Elixir | yes | ❌ historical-row disposition implemented as decided, or explicitly declined with reasons |
| Live drive | yes | ❌ scan a non-primary ISBN on a preview; the shelf shows that edition's cover and page count |

## Definition of Done
- [ ] Verified edition threaded to the placement write — evidence: diff + probe transcript
- [ ] Both write paths covered — evidence: tests
- [ ] Historical rows dispositioned or explicitly declined, with reasoning — evidence: the decision
- [ ] Non-primary-ISBN test passes and reddens under the old behaviour — evidence: probe
- [ ] Live-driven — evidence: screenshot showing the scanned edition's own cover/page count
- [ ] `gdpr-review` verdict cited
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by **#376**, whose placement-disposition rule is downstream of this defect. Related to
**#370**. Needs an owner wave assignment — ⚠️ it degrades the ISBN hard gate's user-visible promise, so
it belongs before launch rather than in the general backlog.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-08-02 by the lead from the #376 agent's finding. The mechanism is cited from live code:
`shelving.ex:377` (the write), `shelving.ex:1327` (`primary_edition_id/1`, ordered `desc: is_primary`),
and `Books.merge_edition/2`'s hardcoded `is_primary: false`.
