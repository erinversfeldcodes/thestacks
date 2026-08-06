# Issue #389: Public-profile "Reader actions" menu + Block-user modal are not Escape/click-away dismissable

## Summary
On the public profile, the ⋯ "Reader actions" overflow menu and the `BlockUserModal` it opens are
keyboard-*reachable* (trigger and items are real `<button>`s) but the **open menu cannot be closed
by Escape or a click away**, and the confirm modal is likewise not Escape-dismissable — there is no
backdrop, and `Main`'s Escape routing does not reach the profile sub-model. Found during #318 8f's
disclosure audit; left out of 8f because the fix is cross-cutting (Main Escape → profile sub-model),
beyond that phase's "attributes/labels only" boundary.

## User Stories
US-19.1.1 / US-19.1.2 (a11y — dismissable overlays), sibling to the block-user flow story.

## Goal
Every open disclosure/modal on the public profile closes by Escape and by click-away, matching the
one-mechanism disclosure pattern #316/#318 8a established for the rest of the app.

## Scope Check
Wire the profile overflow menu + `BlockUserModal` into the same Escape/backdrop close pattern the
nav and account menus use. One surface, cross-cutting into Main's Escape routing. Under the bar.

## Wiring
User-facing. No backend.

## Technical Requirements
1. Escape closes the "Reader actions" menu and the Block confirm modal (route Main's `EscapePressed`
   to the profile sub-model, or give the profile its own key handling consistent with the app pattern).
2. Click-away (a transparent backdrop, as the nav disclosures use) closes the open menu.
3. Focus returns to the ⋯ trigger on close (the disclosure focus-return convention).
4. Program tests: open → Escape → closed; open → backdrop click → closed.

## Reviewer Context
- The pattern to copy is #318 8a's `navDisclosure` (backdrop → `CloseNavMenu`) and `UserMenu`'s
  Escape/Close — do NOT invent a third mechanism.
- Main's Escape routing already gives onboarding first dibs (`onboardingShowing`) and closes nav +
  user menus; extend it to the profile surface without disturbing those.

## Definition of Done
- [x] Reader-actions menu closes on Escape and click-away; focus returns to the trigger — evidence: `BlockUserModalTest` (backdrop present-when-open/absent-when-closed; `MenuClosed`→closed; Escape→`Dismissed`); a stable per-target trigger id + `Browser.Dom.focus` return; **mutation-probed** (disabling the menu-Escape branch reds "Escape closes an open menu → Dismissed", reverted).
- [x] Block confirm modal closes on Escape — evidence: `EscapePressed` closes the confirm modal (or, mid-block, consumes the key while keeping the modal); tested.
- [x] No regression — evidence: Main's `escapeForPage` gives onboarding first dibs then routes to the two host pages, falling through to `closeUserMenuOnEscape`; elm suite 1743/0; orphans 0; check-css clean; no ports.
- [x] `staff-review` verdict recorded below

## Dependencies
Surfaced by **#318** 8f. Sibling of the block-user story. Independent of the rest of Wave 8.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-08-05 from #318 8f's disclosure audit. 8f fixed the labels/pluralisation/aria-live within
its boundary and flagged this as the one real keyboard-dismissal gap it could not fix without
cross-cutting into Main's Escape routing — recorded here rather than absorbed.


## Fixed in-branch 2026-08-06 — staff-review: LGTM
⚠️ **Host correction:** the issue said "public profile", but `BlockUserModal` is actually used by **`Page.Blog.Post` and `Page.Groups.Detail`** (not `Page.Profile`) — the DRY fix went in the shared component + those two hosts + Main's Escape routing (the BookDetail precedent). Escape + click-away backdrop + focus-return all wired to the 8a pattern (`.app-nav__backdrop`), no ports. Mutation-probed non-vacuous; reverted. Assigned Wave 8 (8g); fixed in-wave per the owner rule.
