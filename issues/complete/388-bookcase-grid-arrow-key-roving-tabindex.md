# Issue #388: Bookcase/shelf grid — roving-tabindex arrow-key navigation (deferred from #318 8f)

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
The bookcase/shelf grid is keyboard-*reachable* today — every spine is a real
`<button class="book-button">`, so WCAG 2.1.1 (keyboard-operable) is already satisfied by Tab. What
it lacks is **arrow-key roving-tabindex** navigation (←/→ across a shelf row, ↑/↓ between rows) with
a single tab stop per grid, the richer affordance US-19.1.2 gestures at. Wave 8's a11y phase (8f,
#318 TR-6) recorded this as an **explicit defer** rather than build it under an "attributes-only"
touch-up, and cut this issue so the defer is a tracked work item, not a phantom.

## User Stories
US-19.1.2 (keyboard navigation) — the enhancement leg. The baseline (Tab-reachable) is already met.

## Goal
A reader can traverse a bookcase grid with the arrow keys from a single tab stop, with a visible
focus ring and a defined column model, without regressing the existing Tab reachability or the
overlay/Escape focus logic.

## Scope Check
A new stateful widget (roving tabindex + arrow-key handling) over a width-packed, variable-length
grid, touching both Bookshelf `Msg` families and Main's Escape/overlay focus routing. Genuinely
its own issue — NOT an attribute touch-up. Likely needs a small design pass on up/down column
behaviour first (a width-packed row is not a fixed grid).

## Wiring
User-facing (keyboard). No backend.

## Technical Requirements
1. Decide the column model for ↑/↓ over a width-packed row (nearest-x? fixed columns? wrap?) — a
   short design note in US-19.1.2 before building.
2. Roving tabindex: one tab stop per grid; arrows move focus; Home/End to row ends; focus ring
   visible and `prefers-reduced-motion`-safe.
3. Must NOT regress: existing per-spine Tab reachability, the book-detail overlay open/close focus,
   or Main's Escape routing (which #318 8a/8e/8b touch).
4. Program tests for the roving-tabindex state machine; a keyboard drive at review.

## Reviewer Context
- `book-button` spines already carry the click/keyboard affordance — build ON that, don't replace it.
- Main's Escape/overlay focus is load-bearing (nav disclosures, onboarding trap, arrival door) —
  coordinate, don't collide.

## Definition of Done
- [x] Column model decided + recorded in US-19.1.2 — evidence: owner decision NEAREST-X; `docs/user_stories/US-19.1.2-keyboard-nav.md` decision block added 2026-08-09 (ties → earlier book so ↑↓ does not drift; keydown on the spine buttons, not a global subscription, so Main's Escape routing is untouched)
- [x] Roving-tabindex arrow-key nav on a bookcase grid — evidence: `Page.Bookshelf.GridNav` (pure fn over `(bookId, spineWidth)` rows sharing the packer's `placementSpineWidth`); `GridNavTest.elm` (24 cases incl. the index-model-refuting nearest-x cases + keyDecoder claims exactly 6 keys) + 3 roving program tests in `BookshelfProgramTest.elm`. Mutation-probed: nearest-x → row-head mutation reds exactly the discriminating case; tabindex-always-0 mutation reds all 3 roving tests. KEYBOARD DRIVE DONE 2026-08-09 on the deployed preview (real owner login, /antilibrary, 32 spines): exactly one tabindex-0 spine; ArrowRight moved focus+tab stop with the amber ring visible (screenshot-verified — an occluded automation tab defers Elm's rAF repaint, the #368 filing's own harness note, so every step was read after a forced frame); ArrowDown landed nearest-x on the row below (The Goldfinch → The Book of Sand); End → row end; Enter opened the detail overlay; Escape closed it and returned focus to the SAME spine with the tab stop following — Main's routing intact and composing with the roving state
- [x] No regression to Tab reachability / overlay focus / Escape — evidence: full Elm suite 1772/0 (incl. overlay focus-return + onboarding trap suites); `lint-elm.sh` fully green; the six-key decoder FAILS for Tab/Enter/Space/Escape so their defaults stand; drive re-checks at finalize
- [x] `staff-review` verdict recorded below — see Wave 11 close-out (LGTM WITH NOTES; the noted owed drive is now done)

## Dependencies
Deferred from **#318** (Wave 8 8f). Independent of the rest of Wave 8. Owner to confirm defer-vs-now.

## Agent Assignment
elm-agent + a11y-focused review.

## Progress Notes
Filed 2026-08-05 from #318 8f's recorded defer. Rationale for deferring: WCAG 2.1.1 is already met
(Tab-reachable), and a correct roving-tabindex over a variable-length grid is a new widget well
beyond 8f's attributes-only boundary, with an unanswered up/down UX question. Awaiting owner nod on
whether to schedule now or hold to a later a11y pass.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM WITH NOTES** — GridNav is a pure function over the packer's own widths — the nearest-x tests refute an index model, not just exercise the happy path; keydown on the buttons keeps Main's Escape routing untouched. Note: the deployed-keyboard drive is owed at wave finalize before the remaining DoD box closes.
