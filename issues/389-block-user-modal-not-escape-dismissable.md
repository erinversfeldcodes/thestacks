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
- [ ] Reader-actions menu closes on Escape and click-away; focus returns to the trigger — evidence: program test + drive
- [ ] Block confirm modal closes on Escape — evidence: program test + drive
- [ ] No regression to existing Escape/disclosure behaviour — evidence: suites green + drive
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by **#318** 8f. Sibling of the block-user story. Independent of the rest of Wave 8.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-08-05 from #318 8f's disclosure audit. 8f fixed the labels/pluralisation/aria-live within
its boundary and flagged this as the one real keyboard-dismissal gap it could not fix without
cross-cutting into Main's Escape routing — recorded here rather than absorbed.
