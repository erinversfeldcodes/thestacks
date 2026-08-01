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

**staff-review verdict: LGTM** (2026-07-31, lead, Mode B on 3a1f9d22). Praise: (a) it built **one choke point rather than five per-branch checks** — `mutationToken` returns `Nothing` under `readOnly`, and since every mutating branch pattern-matches `Just token`, none is selectable. A *new* mutating branch inherits the guard by construction, because a token is the thing it needs to issue a request and this is the only place one comes from. Lead-verified: **zero** references to `model.token` inside `handleOrganiser`; (b) it kept the view check and **re-documented what it now is** — "hides the affordance; no longer *is* the guard" — rather than deleting it, because a control that would 403 should not be drawn; (c) it **deliberately avoided ProgramTest** for the core assertion, reasoning that the harness's effects come from `TestHelpers.libraryEffects`, so a program test would observe the *translator's* answer rather than the page's. That is exactly the defect class the lead filed as **#347** during Wave 5, arrived at independently; (d) better still, `TestHelpers.libraryEffects` now **calls `Bookshelf.mutationToken`** instead of re-implementing the rule — lead-verified at `TestHelpers.elm:1119` — so the mirror cannot drift from production; (e) the five mutating branches are expressed **as data** (`mutatingOrganiserDrives`) so both suites run identical drives and a guard covering 4 of 5 cannot read as complete; (f) it proved the **positive controls are not vacuous** with a third probe — forcing the guard always-on reddens all five owner controls, showing `Expect.notEqual Cmd.none` genuinely discriminates.
**No-regression evidence done properly:** with the guard in place it *unregistered* the three new suites and got **1374/0** — every pre-existing test green under the new dispatch — then 1374 + 11 = **1385/0** with them restored. Lead re-ran: **1385 passed, 0 failed.**
Probes (all reverted via Edit, `grep` verified): dispatch on `model.token` → 5 red; `if False` → 6 red; `if True` → 6 red (the positive-control check).
**Findings — one fixed by the lead immediately, since it was the lead's own gap:** (1) ⚠️ **`just bootstrap-worktree` did not provide `frontend/node_modules`**, so `npx elm-test`, `elm-review` and `elm-format` could not run in a fresh worktree and *every* Elm agent has been hand-rolling a link or install. Fixed: the script now symlinks `frontend/` and `apps/core/assets/` node_modules from the main checkout. (2) ⚠️ **And the trap that came with it** — `.gitignore` carried `frontend/node_modules/` and `node_modules/`, both **directory-only** patterns, which do **not** match a symlink; a linked `node_modules` showed as untracked and `git add -A` would have committed ~200 MB. The agent hit this and removed its link before staging. Slash-free twins added and verified the way this project requires — by replacing the real directory with an actual symlink and running `git check-ignore -v` (`.gitignore:31 → IGNORED`), not by reading the file. (3) `reloadShelves` (`Page/Bookshelf.elm:501`) would refetch the *viewer's own* bookshelf rather than the profile shelf in read-only mode — now **latent rather than live**, since `ShelfMutated` is unreachable under `readOnly` after this change. Worth a one-line hardening when someone next touches it.
Gates: `lint-elm.sh` clean (vacuous-guard ✓, prose assertions 36 checked ✓, orphan classes **88 / 0 unstyled — zero added** ✓, CSS 732 rules 0 collisions ✓), `elm-format --validate` clean on `src/` and `tests/`, `elm-review` no errors, `npm audit` 0 vulnerabilities.
