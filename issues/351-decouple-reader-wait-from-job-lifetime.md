# Issue #351: A reader must never be held hostage to the upload page

## Summary
Raised by the owner on 2026-07-31 after #342 derived the SSE deadline from actual job death, and settled by owner design decisions the same day.

**The defect is not just that the wait is long — it is that leaving loses the work.** Today the reader gets a static spinner and `"Processing image..."`, and because the `uploaded_images` row stays `pending` across retries, **no SSE frame is broadcast between attempts**: the client receives literally nothing for up to 23 minutes. If the reader closes the tab, `IdentifyBookJob` still completes, the row goes `resolved` with its candidates, the GPU call is paid for — and **no route or surface can ever reach that result again**. It sits until the 30-day retention sweep deletes it.

There is no route that lists uploads awaiting confirmation: the upload routes are `init`, `commit`, `reject-identification`, and the status stream. The current design's only answer to "what if I navigate away" is "don't", which is the hostage-taking this issue exists to remove.

## The governing invariant (owner ruling 2026-07-31)
> *"a user should never be held hostage to a page and incorrect classifications should never end up on shelves they are not intended for, so we need to balance the asynchronous part (re-attempting) and the synchronous (did we identify correctly? great, it's added to the platform, now where do you want us to put your copy?)"*

```
ASYNC  — reader free to leave at any point
  upload → identify → retry as needed → row: resolved + candidate(s)

SYNC   — reader present, whenever that is
  "We think it's this book" → yes → which shelf? → placed
                            → no  → try again (exclusion list; already built)
```

**Nothing reaches a shelf without the reader confirming the identification and choosing the shelf.** This is preserved *by construction*, not by new enforcement: `IdentifyBookJob` finishing already does not place a book — it sets `resolved` with `book_id`/`book_ids`, and placement is a separate user-driven action. The async/sync boundary already exists in the data model. What is missing is only the ability to leave and come back.

## Owner design decisions (binding)
1. **Where pending confirmations live:** *"an inbox that's accessible from the upload page itself."*
2. **How the reader is alerted:** *"a notification count on the add a book navigation marker so one can easily see that there are pending items."*
3. **Nav placement:** *"we don't need to render it outside of the drop down, it can remain low-but-easy-visibility."* → **no nav promotion**; the count renders on the existing `Add Book` entry inside the `Catalogue` dropdown. **#351 therefore does NOT depend on Wave 8's nav IA rebuild (#318, item 8a).**

**Consequence worth stating:** with no email and no push, there is **no notification delivery path to build** — no fifth `notify_*` consent column, and **no `image.resolved` subscriber**. The badge count is a query. #334's documented rationale for leaving `image.*` in `@unsubscribed` still stands and should not be disturbed.

## User Stories
US-1.1.1 (upload failure UX), US-1.1.3 (photo → book), US-1.1.5 (manual entry parity).

## Goal
A reader can close the tab mid-upload and lose nothing. Identification finishes without them; confirmation waits for them; a shelf is only ever chosen by a human.

## Scope Check
One query + one route, one inbox surface on the existing upload page, one badge, and the leave-affordance copy. Watch the size: if the inbox grows its own page and routing, split it.

## Wiring
Router wiring: **one new read-only route** listing the current user's uploads awaiting attention. User-facing on completion. Reuses the existing confirm/reject/place flow entirely — do not build a second one.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Current behaviour | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| Reader leaves mid-upload and returns | none exists | resolved row is unreachable; deleted at 30 days | ❌ | build in-scope |
| Reader sees there is something to confirm | none exists | no indicator anywhere | ❌ | build in-scope |
| Reader is told a slow upload may be left | static "Processing image..." | implies imminence, forever | ❌ | build in-scope |
| Nothing lands on a shelf unconfirmed | confirm → shelf → place | already correct | ✅ | preserve — assert it |

## Technical Requirements
1. **Define "awaiting attention" precisely, then query it.** The obvious predicate — `status = 'resolved'` with no placement for that user — needs care: the reader may have added the book by another route (manual ISBN, or a different photo). State the predicate, and make sure a book the reader already shelved does not sit in the inbox nagging them forever.
2. **Include terminal failures, with different copy.** A `rejected` upload the reader never witnessed is *also* lost work — today they simply never learn. The inbox should surface it ("we couldn't identify this one") so failure is not silent. Distinguish it clearly from "ready to confirm"; do not let a failure count as a pending confirmation.
3. **The inbox resumes the existing flow.** Selecting an item enters the same "We think it's this book → yes → which shelf" path, including "No, try again" with its cumulative exclusion list. **Do not reimplement the confirm flow** — that is how the DIY drift #343 just deleted came to exist.
4. **The badge count must not lie.** Zero pending renders no badge, not a `0`. The count and the inbox must derive from the same query, or they will disagree.
5. **Offer the exit honestly.** While waiting, the copy should stop implying imminence and tell the reader they may leave — driven by elapsed time, which the client genuinely knows. ⚠️ Do **not** claim "retrying" or "attempt 2 of 3": no attempt data exists on the wire, and inventing it client-side would be a lie dressed as reassurance.
6. **Do not weaken #342's terminal guarantee.** `identify_book_job_terminal_test.exs` must stay green. Every job exit still leaves the row terminal; this issue changes who is watching, not what the worker promises.

## Reviewer Context
- ⚠️ **The 30-day image retention sweep deletes inbox items.** An upload that has waited a month vanishes. Decide whether that is acceptable (probably yes) and say so, but do not let it surprise a reader mid-flow.
- ⚠️ **#342's SSE derivation is correct — do not revert it.** The old hardcoded 360s expired while jobs were still legitimately running; that was the bug.
- ⚠️ The SSE decoder is **strict** since #328 (six required snake_case fields). Any new frame means proto + decoder together; heartbeat frames deliberately fail decode and fall to the `Err _ -> ignore` branch.
- The `Add Book` entry lives at `frontend/src/Main.elm` inside `navDropdown route Catalogue "Catalogue" [ (Search, "Search"), (Upload, "Add Book") ]`. Per the owner ruling it **stays there**. Consider whether the count also needs a subtle mark on the `Catalogue` trigger so it is discoverable while the dropdown is closed — ⚠️ **this is the reviewer's interpretation of "low-but-easy-visibility", not an owner instruction; confirm before building it.**
- Run `bash scripts/check-orphan-classes.sh` (add zero orphans) and `bash scripts/check-css.sh`.
- ⚠️ Elm pages with tests must expose `Msg(..)`; `elm-review --fix` narrows it back if no test consumes it.
- Related: **#342** (terminal guarantee, the derivation), **#349** (latency data), **#350** (the timeout inversion — some retries today are self-inflicted), **#334** (why `image.*` has no subscriber, and why it still shouldn't).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API calls | yes | ❌ the pending-uploads route returns this user's awaiting items and **only** theirs — an authorisation test, not just a shape test |
| Elm | yes | ❌ inbox lists items; selecting one resumes the existing confirm flow to placement |
| Elm | yes | ❌ badge shows a count when pending, renders nothing at zero |
| Oban jobs | yes | ❌ #342's terminal guarantee still holds — existing suite green, cited |
| Live drive | yes | ❌ **the acceptance test**: upload, close the tab, reopen, find it in the inbox, confirm, place — screenshots |
| Others | no | n/a |

## Definition of Done
- [ ] "Awaiting attention" predicate stated and queried; already-shelved books excluded — evidence: the predicate + test
- [ ] Failures surfaced with distinct copy, not counted as pending confirmations — evidence: test names
- [ ] Inbox resumes the **existing** confirm/reject/place flow — evidence: diff showing no second implementation
- [ ] Badge derives from the same query; nothing rendered at zero — evidence: test
- [ ] Leave-affordance copy is elapsed-time based and claims no attempt data — evidence: diff
- [ ] #342's terminal guarantee unbroken — evidence: `identify_book_job_terminal_test.exs` green
- [ ] **Live-driven: upload → close tab → return → inbox → confirm → shelf** — evidence: screenshots
- [ ] `check-orphan-classes.sh` zero new orphans — evidence: output
- [ ] `staff-review` verdict recorded below

## Dependencies
Related to **#342** (built the derivation this responds to), **#349** and **#350** (both change how often the slow path is hit — the owner ruled on 2026-07-31 that they land first: *measure → fix the inversion → re-read retry frequency → then size this*). **Independent of Wave 8 (#318)** by owner ruling on nav placement. Needs an owner wave assignment.

## Agent Assignment
elm-agent + elixir-agent.

## Progress Notes
Filed 2026-07-31 by the lead from the owner's question on #342's SSE derivation; rewritten the same day around the owner's design decisions.
**Verified from source while scoping:** the SSE payload is a `PollResponse` carrying `{image_id, status, book_id, book_ids, rejection_reason, is_duplicate}` where `status` is the DB status — so no attempt/retry signal exists on the wire, and no broadcast occurs between retries because the row stays `pending`. The waiting copy is a spinner plus `"Processing image..."` (`Page/Upload.elm:880`). The upload routes are `init`, `commit`, `reject-identification` and the status stream — **no route lists pending uploads**. `Add Book` is inside the `Catalogue` dropdown, not a top-level nav item.
**Numbers behind the 23 minutes:** `attempt_timeout_ms = 2 × 210_000 + 30_000 = 450_000`; `backoff/1` is deterministic (jitter deliberately removed so the bound is a bound); worst case `3 × 450_000 + 36_000 = 1_386_000 ms`.
