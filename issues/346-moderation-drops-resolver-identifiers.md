# Issue #346: The upload path drops the resolver identifiers it just paid for

## Summary
Found by #341 while collapsing the two create transactions, and confirmed by the lead. `Moderation.build_book_attrs/4` (`apps/core/lib/stacks/moderation.ex:495-527`) resolves an ISBN and then hands `Books.create/1` an attrs map with **neither `open_library_id` nor `google_books_id`**. Every edition minted from an upload is therefore missing the cross-reference identifiers the resolver returned.

This is precisely the defect #341 just fixed — one caller upstream. #341 collapsed `create/1` and `create_confirmed_book/4` because the latter dropped `google_books_id`; the vision/upload path drops **both**, before the create is even called, so the unified transaction never sees them.

## Why it has gone unnoticed
The upload path sets `verification_source` **explicitly** (`barcode_unverified` on the barcode fast path), so it never falls through to `Books.verification_source_from/1` — which is the function that would otherwise have noticed there are no identifiers to read provenance from. The explicit set is correct on its own terms; it just means the missing identifiers produce no visible symptom.

## User Stories
US-1.1.2 (ISBN gate provenance), US-1.1.3 (photo → book).

## Goal
An edition created from an upload carries the same identifiers as one created from manual entry or confirm. Provenance does not depend on which door the book came through.

## Scope Check
One function in one context module, plus its tests. Well under the bar.

## Wiring
Router wiring: none. Internal — the identifiers become visible via `ProtoJSON.edition/1`, which already serialises them.

## Feature-Completeness Pre-Check
n/a — no new story surface. The pre-check that matters is a **zero/null sweep**: count upload-created editions with NULL `open_library_id` AND NULL `google_books_id` before the fix, as the evidence the defect is real and its size.

## Technical Requirements
1. **Pass the resolver's identifiers through** `build_book_attrs/4` into the create. The unified `create_work/2` (from #341) already accepts and persists them — this is a plumbing fix, not a schema change.
2. **Do not disturb the explicit `verification_source`** on the barcode fast path. `barcode_unverified` is deliberate and correct: a barcode scan that has not been confirmed against an external catalogue must not claim to have been. Passing identifiers through and stating provenance explicitly are independent, and both should hold.
3. **Null-sweep the existing rows** and decide whether a backfill is warranted. If it is, use the `Stacks.DataCorrection` mechanism built in #339 (dry-run by default, idempotent, audited) rather than an ad-hoc migration — that is the pattern the owner asked for, and this is exactly its second consumer.
4. **Guard it.** The reason this survived is that nothing asserted the identifiers on the upload path. Add the assertion that would have caught it.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only <the wave branch this is scheduled into>` FIRST — local, unpushed; no `git fetch`, no `origin/`. Copy `.env`; regenerate proto artifacts; `just run` for mix; `caffeinate -i` for long suites.
- **NEVER revert a probe with `git checkout`** — use Edit, verify with `grep -c`.
- ⚠️ #341 collapsed the create paths — there is now exactly **one** `Multi.insert(:book, …)` in `books.ex`. Route through it; do not add a second path for the upload case.
- `Books.verification_source_from/1` derives provenance from the identifiers. Once they are passed through, check whether the explicit set on the *non-barcode* upload paths is still the right call or whether derivation is now more truthful — state the decision either way.
- Related prior art: #341 (the same defect downstream), #339 (`Stacks.DataCorrection` for any backfill).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB interactions | yes | ❌ an upload-created edition carries the resolver's identifiers — mutation-probe by dropping one |
| Oban jobs | yes | ❌ the vision/identify path end-to-end preserves them |
| Warehouse | yes | ❌ null-sweep count captured before/after |
| Others | no | n/a |

## Definition of Done
- [ ] Identifiers passed through to the unified create — evidence: diff + test name
- [ ] `verification_source` behaviour on the barcode fast path unchanged — evidence: test still green, cited
- [ ] Null sweep captured; backfill decision stated (via `Stacks.DataCorrection` if taken) — evidence: counts + decision
- [ ] Mutation probe on the new assertion — evidence: red transcript
- [ ] Suites green — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
**#341** (built the unified create this routes into; found the defect). Optionally **#339** (`Stacks.DataCorrection`) if a backfill is taken. Not yet scheduled into a wave — needs an owner assignment.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-31 by the lead from #341's finding 1, during Wave 5.
