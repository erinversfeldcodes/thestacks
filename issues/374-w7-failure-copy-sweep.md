# Issue #374: Four different failures, one message that fits none of them

## Summary
Wave 7 child (7b) of epic **#317**, phase 4. Every failure the reader can hit outside the happy path
currently resolves to a generic apology or, worse, to a spinner that never ends. Four surfaces, one sweep:

1. **Upload failure states** — consume #315's terminal events so an undecodable image, a not-a-book, a
   service outage and a timeout each say what actually happened. Today the reader watches a spinner for up
   to six minutes and is told nothing.
2. **429 (rate-limited)** — currently unstoried. A reader who trips a limit gets no voice-consistent
   explanation and no retry-after.
3. **W-10: settings forms** — distinct copy per cause (422 / 401 / network) using #316's components.
   ⚠️ The 401 leg is already handled by #361's wrapper; this is the 422-vs-network split.
4. **Forgot-password double-send** — disable the control and show state after the first send, so a reader
   who clicks twice does not silently queue two emails.

## User Stories
US-16.2.1 (failure copy). Upload failure legs of US-2.x.

## Goal
Every failure the reader can reach names its own cause, in voice, within seconds.

## Scope Check
⚠️ Four surfaces is at the edge of scope, but they are one concern (failure copy) and share #316's
components. If the upload leg alone exceeds ~200 LOC, split it out rather than growing this.

## Technical Requirements
1. **Distinct copy per upload failure cause**, driven by #315's terminal events — not by a timeout guess.
   ⚠️ "Could not process your image" for all four causes is what exists now; the point is the distinction.
2. **⚠️ Copy must not assert a cause the app does not know.** The Wave 6 drive found `Page/Login.elm:998`
   mapping *any* unhandled status to "Invalid email or password", so a 502 told readers their credentials
   were wrong (see **#369** requirement 5). Do not repeat that shape here: an unknown failure says it is
   unknown.
3. **429 copy with retry-after where the server provides it**, consistent with the existing 423 lockout copy.
4. **Settings forms: 422 vs network** distinguished, using `Components.SaveButton` and the status notices
   from #363.
5. **Forgot-password: disable + state after first send.** ⚠️ Must not leak enumeration — the disabled state
   is identical whether or not the address exists.
6. **Each failure state reachable in ≤5s.** A correct message the reader waits six minutes for is not a fix.

## Reviewer Context
- ⚠️ **`Login.elm` is contended** — #373 edits it first (resend affordance). Rebase onto #373; do not start
  from `main`.
- ⚠️ **`Page/Upload.elm` is contended with #351**, which reworks it substantially (async identify, inbox).
  This child merges **first**, while the file is small; #351 builds on the copy this establishes.
- Read #362's `loadError` in `Page/Bookshelf.elm` as the exemplar — it splits `Timeout` from `NetworkError`
  and deliberately stays generic on a 500, with the reasoning written down. ⚠️ It also shipped a string
  ending "then try again" with no retry control (**#368**) — copy and affordance must agree.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ one test per upload failure cause → its own copy |
| Elm | yes | ❌ unknown failure does not assert a known cause — probe by adding an unmapped status |
| Elm | yes | ❌ settings 422 vs network distinguished |
| Elm | yes | ❌ forgot-password second send blocked; disabled state existence-independent |
| E2E | yes | ❌ 429 copy spec; forced upload failures each render in ≤5s |
| Live drive | yes | ❌ **acceptance**: force each cause on preview, screenshot each |

## Definition of Done
- [x] Four causes, four messages — evidence: `UploadProgramTest` `inbox_names_the_failure_cause` asserts all four distinct strings (vision_unavailable / isbn_not_found / not_a_book / unknown), and `upload-pipeline.spec.ts` drives each terminal SSE state live (32 passed against the preview 2026-08-04). Each message is keyed off a terminal event, not a guess.
- [x] Unknown never claims a known cause — evidence: the fourth case (`Nothing`) renders "we cannot say why … It may be nothing to do with the photo". Probe: pointing the unknown-cause copy at the not_a_book message → **4 failures** in `inbox_names_the_failure_cause`; reverted → 54/54.
- [x] 429 copy with retry-after — evidence: `FailureCopyTest` reads the delta-seconds header, ignores an HTTP-date, and ⛔ invents no number when the wait is unknown; `waitPhrase` ⛔ rounds UP. 18 tests.
- [x] Settings 422 vs network split — evidence: `FailureCopyTest` "a 422 sends the reader to a reload, not a repeat" and "a dropped connection says the change was not saved" — the two failures give opposite instructions.
- [x] Double-send blocked without leaking existence — evidence: shares #373's resend machinery; `double_send_is_impossible` (the second press starts nothing, proved by the `simulateHttpOk` that consumes the first), and the response is address-independent (the byte-identical live capture in #373).
- [x] Every failure state reached on a live drive — evidence: `upload-pipeline.spec.ts` against the preview, 32 passed in 43.2s (each SSE terminal state injected and its copy asserted). ⚠️ 2 further failures in that file were the Multi-format MERGE tests — NOT unrelated: they asserted the removed `/2 editions/` copy after this branch's commit `32f3219b` changed the merge-completion card to name the server's actual row ("The Paperback edition (ISBN 9780151446476) is now listed…", #355). Own-branch test drift, not a follow-up: both assertions updated to the shipped copy in the same wave; 5/5 green against the preview 2026-08-05. No #386 filed.
- [x] `staff-review` verdict recorded below

## Dependencies
Child of **#317**. Depends on **#315** (terminal events — complete) and **#316** (components — complete).
⚠️ Merges **after #373** (shares `Login.elm`) and **before #351** (shares `Page/Upload.elm`). Reason: file
ownership. Related to **#368** and **#369** requirement 5, which are the same defect class on other surfaces.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-08-01 by the lead at Wave 7 kickoff, from #317 phase 4.

## Progress Notes (review)
- 2026-08-04: **staff-review: LGTM.** The design principle — a message per terminal cause, and an
  explicit "we cannot say why" for the unknown rather than a plausible-but-wrong guess — is the same
  ethic `parse_events/2` holds, and the four-message probe (unknown borrows a known message → 4
  failures) proves it is load-bearing. `FailureCopy`'s 429 handling refuses to invent a wait and rounds
  up, both pinned by ⛔ tests. Driven live via the upload-pipeline spec (32 passed).
