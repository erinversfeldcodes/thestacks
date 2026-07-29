# Issue #310: Convert the 89 test-hook classes to `data-testid`

## Summary
89 class names exist only to be found by a test or E2E selector — they carry no styling and never
will. The project's convention for that is `data-testid` (`Util.TestId.testId`, already used widely,
and the anchor `e2e/tests/helpers.ts` prefers). Using a class instead conflates "how this looks" with
"how a test finds it".

Split out of **#306**, which styled the other 309 and exempted these as verified hooks.

## User Stories
None. Test-suite and markup hygiene.

## Goal
No class exists solely as a test selector, and `check-orphan-classes.sh` reports 0 orphans of any kind.

## Scope Check
- More than 3 controllers? → None.
- More than 2 new endpoints? → None.
- More than ~300 lines? → Borderline: 89 markup sites + 89 assertion sites. **Split by test file**,
  one PR per file, so each diff is reviewable per assertion.
- Unrelated concerns? → No.

## Wiring
Implementation-only. `scripts/check-orphan-classes.sh --hooks` is the authoritative list.

## Technical Requirements
- `scripts/check-orphan-classes.sh --hooks` enumerates all 89.
- Each conversion is two edits that must land together: the Elm view (`class "x"` → `testId "x"`, or
  both where the class is *also* styled — check first) and every selector referencing it.
- ⚠️ **A converted assertion must still assert the same thing.** The failure mode is a selector that
  silently matches nothing afterwards, which is #302's defect class exactly: the test goes green and
  stops guarding anything. For each conversion, **mutation-probe the assertion** — break the feature
  it guards and confirm it fails.
- Once the last one is converted, drop the hook-exemption branch from
  `check-orphan-classes.sh` so the gate becomes simply "0 orphans", and delete `--hooks`.

## Reviewer Context
- ⚠️ Some of the 89 may be styled **and** used as a hook. Those keep the class and gain a
  `data-testid`; they must not have the class removed. `grep` the stylesheet before editing.
- `#306` deliberately did NOT do this, for the reason above: 89 quietly-weakened assertions would be
  a regression that reads as a cleanup.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm unit | yes | the assertions being edited — each needs a probe after conversion |
| E2E | yes | same, for `e2e/tests/*.ts` selectors |
| Presentation | yes | `check-orphan-classes.sh` reaching 0 with no exemption branch |

## Definition of Done
- [ ] All 89 converted or documented as legitimately both-styled-and-hooked — evidence:
      `--hooks` reports 0
- [ ] **Every** converted assertion mutation-probed — evidence: per-file, the break and the failure
- [ ] The hook-exemption branch removed from `check-orphan-classes.sh`; gate is `0 orphans`
- [ ] `just run just verify` passes
- [ ] `gdpr-review`: n/a — markup attributes only. Stated, not skipped.

## Dependencies
Depends on **#306** (done — it established and verified the list of 89).

## Agent Assignment
`elm-agent`.

## Progress Notes
- 2026-07-29: Split from #306. The exemption #306 left behind is *verified* (a class only counts as a
  hook if it really appears in a test source), so nothing is being waved through meanwhile — but a
  verified exemption is still an exemption, and this is how it ends.
