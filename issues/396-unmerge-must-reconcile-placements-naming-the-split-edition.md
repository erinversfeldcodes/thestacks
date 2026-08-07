# Issue #396: Un-merge must reconcile a placement that names the split edition (post-#378)

> **Campaign assignment:** Wave 11 (launch gates) — surfaced by #378 (2026-08-07).

## Summary
#376's owner-only un-merge decided NOT to move placements, justified by "no placement in the
system has ever named a merged edition" — every placement pointed at the work's *primary* edition.
**#378 invalidates that premise:** `Shelving.place_book/4` now records the *scanned* edition, so a
placement created after #378 can name a non-primary (and later-merged) edition. When un-merge
reparents that edition to a new work, a placement whose `book_edition_id` is the split edition keeps
pointing at it across the reparent — leaving `book_id` (old work) and `book_edition_id` (now on the
new work) on **different works**. No crash (both FKs still resolve), but a logical inconsistency.

## Goal
Un-merge leaves every placement internally consistent: a placement that names the edition being
split off is either re-pointed to the surviving work's primary edition or moved to the new work
(owner's/design choice), with the rule documented — so `book_id` and `book_edition_id` never name
different works.

## Scope Check
`Stacks.DataCorrection.UnmergeEdition` + its test. One module. Owner-only path. Under the bar.

## Technical Requirements
1. In `unmerge_edition.ex`, after reparenting the edition, find placements whose
   `book_edition_id` == the split edition and reconcile them (decision: re-point to the surviving
   work's primary edition is the safe default; moving to the new work is the alternative — pick and
   document, owner rules if ambiguous).
2. Update the docstring (currently marks this as tracked-here) to state the implemented rule.
3. Test: create a placement naming a non-primary edition (via the #378 scan path), un-merge that
   edition, assert the placement is consistent (`book_id` and `book_edition_id` on the same work).

## Definition of Done
- [ ] Un-merge reconciles placements naming the split edition — evidence: the new test reds without the fix
- [ ] Docstring states the implemented rule (not "tracked in #396")
- [ ] `gdpr-review` n/a; `staff-review` verdict recorded

## Dependencies
Downstream of #378 (which introduced edition-specific placements) and #376 (the un-merge path). Owner-only, so not launch-blocking for public flows, but should land before un-merge is used in anger.

## Progress Notes
Filed 2026-08-07 from the #378 implementation — #378 correctly records the scanned edition, which
weakens #376's "placements always point at primary" premise. Recorded truthfully in
`unmerge_edition.ex`'s docstring.
