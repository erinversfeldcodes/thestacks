# Issue #332: The read-only bookshelf's mutation guard is view-only

## Summary
`Page.Bookshelf.handleOrganiser` dispatches shelf create/delete/reorder on `( subMsg, model.token, model.shelves )` with **no `config.readOnly` check** (`frontend/src/Page/Bookshelf.elm:352-354`). A `ShelfOrganiser.AddShelf` message reaching a read-only model therefore issues `POST /api/bookshelves/:apiName/shelves`. The organiser is not *rendered* in read-only mode, so the guard today is the view — not the update function.

## User Stories
US-1.7.1 (shelf organisation), US-1.4.1 / US-10.5.3 (viewing another reader's shelf).

## Goal
A read-only bookshelf cannot issue a mutating request even if a message reaches its update function — the guarantee moves from "the button isn't drawn" to "the branch cannot be taken".

## Scope Check
One Elm module, a handful of lines. No split.

## Wiring
Router wiring: none — behaviour hardening on an existing page.

## Feature-Completeness Pre-Check
n/a — hardening an existing built surface.

## Technical Requirements
- Add `config.readOnly` to the `handleOrganiser` dispatch so every mutating branch is unreachable in read-only mode. Prefer making it *unrepresentable* over adding a runtime check: e.g. the read-only config carries no organiser state at all, so the branch cannot be constructed (Bug-Catching Ladder rung 1–2 rather than a rung-6 guard).
- Keep the existing behaviour for the owner path byte-for-byte; this must not change what an owner can do.
- The regression test belongs beside the existing one: `frontend/tests/Page/BookshelfReadOnlyTest.elm` now has a real effect translator and a positive control (added by #330), so the negative assertion will actually catch this once the guard exists — add a case that drives a synthetic `OrganiserMsg` into the read-only model and asserts zero requests.

## Reviewer Context
- **Discovered by #330** (Wave 3, staff-campaign-2026-07-30) while making that file's "SECURITY" test falsifiable; confirmed independently by the lead: `grep readOnly` over `Page/Bookshelf.elm` shows it only in config records and one view-level check at `:205`.
- **Severity is bounded and should not be overstated.** The request carries the *viewer's* own token, so the server scopes the write to the viewer's own bookshelf of that name — this is not a cross-reader write and not a data leak. What is real is that the module's docstring claimed a defence-in-depth that did not exist (#330 corrected the docstring to describe the actual scope).
- This is the campaign's recurring shape: a correct decision enforced by convention (don't render the control) rather than by structure (the branch cannot be taken).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine | yes | ❌ read-only model + synthetic OrganiserMsg → zero effects (with the existing positive control proving the assertion can fail) |
| 1–13 | no | n/a — one-module hardening |

## Definition of Done
- [ ] `handleOrganiser` cannot mutate in read-only mode — evidence: diff + the new test name
- [ ] Mutation probe: remove the guard → the new test reddens; output quoted — evidence: transcript
- [ ] Owner path unchanged — evidence: existing organiser tests still green at cited count
- [ ] Module docstring matches the implemented guarantee — evidence: diff
- [ ] `staff-review` verdict recorded below

## Dependencies
- #330 (Wave 3) — supplied the real effect translator and positive control this test needs; **complete**, merged.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-30 by staff-execute from #330's discovery. Deliberately not absorbed into #330, which was scope-locked to test files (this is a production change).
