# Issue #355: A successful edition merge is invisible to the reader — twice over

## Summary
Found by the lead's Wave 5 live drive on the preview, 2026-07-31. Driving the **US-1.1.8 same-work merge prompt** end to end: entering `9780099466031` (the Vintage edition of *The Name of the Rose*, absent from the catalogue as an edition but whose *work* exists) correctly produced the merge prompt — *"You already have 'The Name of the Rose' by Umberto Eco. Add this edition to it?"*. Clicking **"Yes, merge"** then succeeded server-side and told the reader nothing.

Two independent defects sit on that one click:

**1. The UI never advances.** `POST /api/books/:id/merge-format` returned **200**, and the screen stayed on the merge prompt — same heading, same buttons. A reader has no way to tell the merge happened, and the obvious recovery (click it again) re-posts a merge that has already been applied.

**2. The book detail serves stale data afterwards.** `GET /api/books/:id` returns **one** edition while the database has **two** on that `book_id` — verified with a cache-buster against the live preview, and confirmed directly in Postgres:

```sql
 isbn          | book_id                              | verification_source
 9780099466031 | a1b2c3d4-0000-0000-0000-000000001031 | google_books        -- merged, invisible
 9780156030410 | a1b2c3d4-0000-0000-0000-000000001031 | barcode_unverified  -- original, shown
```

So "View Book" — the prompt's own follow-on action — shows the reader a book *without* the edition they just added.

## Root cause of (2)
`Stacks.Books.Handlers.CacheInvalidationHandler` invalidates `BookDetailCache` on exactly three event types (`events/registry.ex:39-57`): `book.created`, `book.cover_confirmed`, `blog.associations_suggested`. **Merging an edition emits none of them** — the work is not created, no cover is confirmed, no blog association changes. The handler is built and correctly wired; it is simply not wired to the event that matters, and `merge_edition/2` does not emit an event at all.

This is the campaign's dominant defect class (see the wiring-trace note): the mechanism exists, and nothing connects it to the case in hand.

## Why it survived the test suite
#343's program tests assert the merge **request is made**; #341's tests assert `merge_edition/2` **persists and retains metadata**. Both are true and both pass. Neither asks what the reader sees *after* the 200 — and the cache sits between the two, in a layer neither test crosses. Only a live drive puts the request, the cache and the screen in the same picture.

## User Stories
US-1.1.8 (same-work merge), US-1.1.6 (duplicate awareness).

## Goal
A merge the server accepted is a merge the reader can see: the screen moves on, and the book detail shows the edition.

## Scope Check
One Elm state transition + one cache-invalidation path. Two causes, one user journey — deliberately filed together so neither is fixed while the journey stays broken.

## Wiring
Router wiring: no new routes. This is a wiring *defect*: emit → handler → cache, with the first hop missing.

## Technical Requirements
1. **Advance the UI on a successful merge.** Decide what the reader sees — most likely the same completion card the other paths reach, naming the book and where it now is. ⚠️ Whatever it says must be **true after the cache fix**, not before; a completion card that names an edition the detail page then fails to show is the same defect wearing a nicer coat.
2. **Invalidate `BookDetailCache` on merge.** Prefer emitting a real event and routing it, over calling `BookDetailCache.invalidate/1` inline — the handler and registry already exist, and an inline call is a second mechanism for a job the first one already does. If you emit a new event type, note that `#334`'s registry completeness test and the closed enum gate both apply.
3. **Sweep for siblings.** Merge is unlikely to be the only write that changes a book's detail without emitting one of those three events. Enumerate what else mutates a work or its editions — and say what you found, even if the answer is "nothing else".
4. **Test at the layer that failed.** A test asserting the 200, or asserting `merge_edition/2` persists, would have passed throughout. The regression test must span request → cache → read, which is the boundary neither existing test crosses.

## Reviewer Context
- BOOTSTRAP: **`just bootstrap-worktree`**, then `git merge --ff-only <wave branch>` (local, unpushed — no `git fetch`).
- **NEVER bare `mix`** — `just run mix …`; **`caffeinate -i`** for long suites; **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`. Stage incrementally.
- ⚠️ **The merge itself is correct — do not "fix" it.** Both editions share one `book_id`; there is no W-13 duplicate work. The bug is entirely in what the reader is told and shown.
- ⚠️ `TitleSearchCache` and `ISBNResolverCache` are neighbours with their own TTLs; #352 covers a *different* defect in the former. Don't conflate them.
- Related: **#343** (built the merge prompt), **#341** (`merge_edition/2` retention + the mass-assignment reasoning), **#334** (registry completeness).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ a successful merge advances the screen — probe by leaving the transition out |
| API calls | yes | ❌ request → cache → read: after a merge, `GET /api/books/:id` includes the new edition |
| Event flow | yes | ❌ merge emits an event the invalidation handler receives |
| Live drive | yes | ❌ **the acceptance test**: merge on preview, then View Book shows both editions — screenshots |
| Others | no | n/a |

## Definition of Done
- [ ] UI advances on merge, saying something true post-fix — evidence: program test + screenshot
- [ ] Cache invalidated via the existing event/handler path — evidence: diff + test
- [ ] Sibling sweep reported — evidence: the list, even if empty
- [ ] Regression test spans request → cache → read — evidence: test name + probe transcript
- [ ] Live-driven on preview — evidence: screenshots
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by the Wave 5 live drive. Related to **#343**, **#341**, **#334**. Needs an owner wave assignment.

## Agent Assignment
elm-agent + elixir-agent.

## Progress Notes
Filed 2026-07-31 by the lead during the Wave 5 live drive on `stacks-core-pr-feat-campaign-w5-315`. The merge prompt itself worked exactly as designed — this issue is about everything after the click. Cache-buster query and direct Postgres verification both included above; the stale read is not a browser cache.
