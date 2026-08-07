# Issue #380: Three book-detail specs fail at the worker count the suite ships with

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
Found by the Wave 7 live drive, 2026-08-02/03. Three `book-detail.spec.ts` specs fail at the
**default** worker count and pass serially:

| Spec | `--workers=4` (default) | `--workers=1` |
|---|---|---|
| `:168` Escape key closes the overlay; URL never changes | ✘ 1.5m timeout | ✓ |
| `:210` Tab never moves focus outside the overlay | ✘ 1.5m timeout | ✓ |
| `:241` Tab from the trailing sentinel wraps to the close button | ✘ 1.5m timeout | ✓ |

Serial run: **27 passed / 0 failed** (10.2m).

⚠️ **This is a test-design defect, not environmental noise.** `playwright.config.ts:21` sets
`workers: process.env.CI ? 2 : 4` — so the suite's **own shipped configuration** is what makes these
fail. A test that cannot survive the concurrency it is configured for is broken, and there is no such
thing as an acceptable failure unless the test exists to assert a failure path.

## Mechanism
These specs share a file with tests that deliberately induce slow responses, and they run against one
preview VM. The tell is in the *passing* serial run's own timings:

```
✓ :347 loading state is visible before a delayed response resolves   (1.3m)
✓ :515 removing the book returns focus to the main landmark          (49.1s)
```

A test that takes **1.3 minutes while passing** has almost no headroom under a default 90 s timeout
once three others are contending for the same backend. The focus-contract specs are the ones that
tip over, but they are the symptom — the file's time budget is the defect.

## User Stories
None — test-suite integrity. Protects the overlay's keyboard-accessibility contract (punch #11/#12,
#295), which is a real user guarantee and must keep being asserted.

## Scope Check
One spec file's timing/isolation design. Single concern.

## Technical Requirements
1. **Make each spec's timeout derive from the delay it induces**, not from the default. A spec that
   mocks a 60 s delayed response and then asserts on a loading state needs a budget that says so.
   ⚠️ Do not simply raise the global timeout — that hides the next slow test instead of pricing this one.
2. **Stop the slow specs from contending with the focus specs.** Options: move the deliberately-slow
   load/error specs into their own `describe` with `test.describe.configure({ mode: 'serial' })`, or
   split them into a separate file. ⚠️ Prefer whichever keeps the focus specs runnable **in parallel** —
   serialising the whole file trades a real defect for a slow suite and hides the next instance.
3. **Do not weaken the assertions.** The focus trap, the Escape scoping and the sentinel wrap-back are
   genuine accessibility guarantees. ⚠️ A `try/catch`, a raised tolerance, or a `test.skip` under load
   would turn a broken test into a lying one — the exact defect class this campaign keeps finding.
4. **Prove it at the shipped worker count.** ⚠️ `--workers=1` passing is the state that already exists
   and proves nothing. The acceptance run is `--project=chromium --workers=4` against a preview, with
   the three specs green, repeated enough times to mean something. State how many runs.

## Reviewer Context
- ⚠️ **Do not read these as a #375 regression.** The lead suspected exactly that — #375 added an undo
  toast wired through `BookDetail.undoableRemoval`, and a new focusable element near the overlay is a
  plausible focus-trap leak. It was wrong: 27/27 serially, and the *remove-modal* focus specs pass in
  both modes. That hypothesis is tested and dead; do not re-run it.
- Related: **#371** — the same class in `admin-session.spec.ts` (three specs sharing one mutable MFA
  factor). Different mechanism, same lesson. Fixing both is what makes "the suite is green" mean
  something.
- The preview VM must be **1 GB**, not the 512 MB default — see **#369**. At 512 MB the auth setup
  alone OOM-kills it and every downstream result is noise.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| E2E | yes | ❌ all three pass at `--workers=4` against a preview, repeatedly |
| E2E | yes | ❌ assertions unchanged — focus trap, Escape scoping, sentinel wrap still asserted |
| E2E | yes | ❌ the deliberately-slow specs still assert what they did, at a budget that names its own delay |

## Definition of Done
- [ ] Three specs green at the shipped worker count — evidence: N runs, quoted
- [ ] Timeouts derived from induced delay, not raised globally — evidence: diff
- [ ] No assertion weakened, skipped or made conditional — evidence: diff
- [ ] `staff-review` verdict recorded below

## Dependencies
Found by the Wave 7 drive; independent of Wave 7's changes. Pairs with **#371**. Both must land before
"the E2E suite is green" is a claim anyone can rely on.

## Agent Assignment
qa / e2e.

## Progress Notes
Filed 2026-08-03 by the lead. Both runs are the lead's own against
`stacks-core-pr-feat-campaign-w7-317.fly.dev` (1 GB): the default-worker drive showing the three
failures, and the `--workers=1` re-run showing 27/0. The passing-run timings quoted above are from the
serial run's own output.

## Verification (2026-08-07, Wave 11 verify-and-close)
ALREADY-FIXED (`babcc4be`) and closed on acceptance evidence: 3× consecutive `--project=chromium admin-session.spec.ts book-detail.spec.ts` at the shipped worker count = **33 passed** each (54.9s / 1.4m / 56.1s), recorded in #371's Progress Notes. #371 = per-run owner-MFA factor isolation (mutation-probed); #380 = the injected sleep became a hold-until-observed promise, removing the contention race at source. Distinct root causes (shared server state vs wall-clock contention). ⚠️ The intermittent mfa-confirm 422 is tracked separately as #394.
