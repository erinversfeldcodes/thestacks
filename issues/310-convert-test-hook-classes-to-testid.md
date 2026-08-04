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

## Measurement (2026-08-04) — what the work actually is

Sized before starting, because "89 conversions" was not an accurate description:

| | |
|---|---|
| Claimed hooks | 88 |
| **Bogus exemptions** — name merely *mentioned* in a test, never a selector | **14 → FIXED, see below** |
| Genuinely used as a selector | 74 |
| ...of those, already styled → keep the class, **add** a testid | 31 |
| ...pure hooks → convert | 43 |
| Test files touched | 63 |
| Sites in **negative** assertions (vacuity risk) | 12, of which 1 was itself a false positive |

**The 12 negative-assertion sites are the actual engineering; the ~96 positive occurrences are safe by
construction** — a positive assertion that stops matching fails loudly, so the suite is the evidence.
That split is what makes the remainder mechanical, and it is why this issue should still be one PR per
test file.

### ⛔ Found while sizing it: 14 exemptions were bogus, and one was user-visible

`check-orphan-classes.sh` exempted a class if its name appeared **anywhere** in a test source — a bare
substring match. So:

- **`.success` had no CSS rule and five call sites** across Settings (Privacy ×3, Password,
  Notifications). "Password changed successfully" was rendering as unstyled default text. It was exempt
  because the string `success` sits inside the identifier `successCopy` in a test.
- `app-nav`, `comment`, `profile`, `blog-post`, `block-user`, `removal-queue`, `writing-assistant` and
  five more were exempt for the same reason — substrings of longer names, or of ordinary prose.

Fixed in two parts: the check now requires the class to appear in a real selector
(`Selector.class "x"`, `getByTestId("x")`, `[data-testid="x"]`, or `.x` inside a quoted selector
string), and all 14 are now styled. Probed: a class named `reader` — mentioned in test sources, never a
selector — is now correctly refused (exit 1), where before it would have been waved through.

⚠️ The generalisable lesson, and the reason this is recorded rather than quietly patched: **an
exemption is only as strong as the thing it verifies.** I described this exemption as "verified rather
than asserted" in #306, and it was — it verified that the name appeared in a test file, which turns out
to verify almost nothing.

## Progress Notes
- 2026-07-29: Split from #306. The exemption #306 left behind is *verified* (a class only counts as a
  hook if it really appears in a test source), so nothing is being waved through meanwhile — but a
  verified exemption is still an exemption, and this is how it ends.
- 2026-08-04: Sized and de-risked, not yet converted. The measurement above is the deliverable of this
  pass: it turns an undifferentiated 88 into 12 sites needing judgement and ~96 that are mechanical,
  and it found 14 bogus exemptions including a user-visible unstyled success message. The conversion
  itself remains, one PR per test file, with the 12 negative-assertion sites probed individually.

