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
- [ ] Four upload causes, four messages, each from a terminal event — evidence: tests + screenshots
- [ ] Unknown status never claims a known cause — evidence: probe transcript
- [ ] 429 copy with retry-after — evidence: test + drive
- [ ] Settings 422 vs network split — evidence: tests
- [ ] Double-send blocked without leaking existence — evidence: test + reasoning
- [ ] Every state reached in ≤5s on a live drive — evidence: timings + screenshots
- [ ] `staff-review` verdict recorded below

## Dependencies
Child of **#317**. Depends on **#315** (terminal events — complete) and **#316** (components — complete).
⚠️ Merges **after #373** (shares `Login.elm`) and **before #351** (shares `Page/Upload.elm`). Reason: file
ownership. Related to **#368** and **#369** requirement 5, which are the same defect class on other surfaces.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-08-01 by the lead at Wave 7 kickoff, from #317 phase 4.
