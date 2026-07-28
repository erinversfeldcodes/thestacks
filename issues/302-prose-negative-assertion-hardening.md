# Issue #302: Harden negative test assertions that match on user-visible prose

## Summary
A negative assertion matching on copy (`Query.hasNot [ Selector.text "Add shelf" ]`) is one
wording change away from passing vacuously. One SECURITY assertion had already been disarmed this
way. Repoint feature guards onto `data-testid` anchors and add a check so it cannot recur silently.

## User Stories
None directly — it protects the guarantees of every story with a negative assertion. The disarmed
one belonged to US-10.5.3 (read-only shelf browsing).

## Goal
No assertion that guards a *feature* (as opposed to specific copy) depends on prose. Prose-based
negatives remain only where the copy itself is the subject, and each is paired with a positive
assertion that the same string renders in the sibling state — so a rename fails loudly.

## Scope Check
- More than 3 controllers? → No controllers; test-only.
- More than 2 new endpoints? → None.
- More than ~300 lines? → No. 19 call sites, most needing no change.
- Unrelated concerns? → No.

## Wiring
Router wiring: implementation-only — test-suite hardening, no user-facing surface.

## Technical Requirements

**The 2026-07-28 sweep, and its honest result.** 19 prose-matching negative assertions exist:

```sh
grep -rnE "(hasNot|expectViewHasNot) \[ Selector\.text \"" frontend/tests/
```

Cross-checking each string against `frontend/src/` found 3 whose exact text appears nowhere in
the source — the shape that can never fail:

| Site | String | Verdict |
|---|---|---|
| `frontend/tests/NavigationProgramTest.elm:154` | `"The Power of Habit"` | **Fine** — fixture data; renders if the bug returns |
| `frontend/tests/Page/ProfileTest.elm:102` | `"Ada Lovelace"` | **Fine** — fixture data; same |
| `frontend/tests/MainViewTest.elm:67` | `"View Antilibrary"` | **Fine, but fragile** — a deliberate "stays deleted" guard for pre-#235 copy |

So **no currently-live feature guard is vacuous**. The one that was —
`BookshelfReadOnlyTest.noAddShelfControl`, which asserted no *"Add shelf"* button while the button
says *"Add a shelf"* — was fixed on 2026-07-28 and mutation-probed.

⚠️ **The dangerous shape is narrower than "matches on prose", and this is the point of the
issue.** A prose negative is dangerous when **the feature it guards renders near-identical copy in
a sibling state**. Then the assertion looks meaningful, reads meaningful in review, and is inert.
`"Add shelf"` vs `"Add a shelf"` is one word. A plain string-absent-from-source check does *not*
find these — it would have missed the real one, because "Add a shelf" **is** in source. Detection
needs fuzzy matching (normalise case/articles/punctuation, then look for a near-neighbour in
`frontend/src/`), or the convention below.

**The convention to land:** a negative assertion about a *feature's presence* must anchor on
`data-testid`; a negative assertion about *copy* must be paired with a positive assertion that the
same literal renders somewhere. `Util.TestId.testId` already exists and is used widely.

## Reviewer Context
- `data-testid` is the project's established hook (`Util.TestId.testId`), and
  `e2e/tests/helpers.ts` uses the same anchors — so repointing improves E2E/unit consistency too.
- ⚠️ Related but distinct, already tracked: **16 `if (count > 0)` guards in `e2e/tests/`** make
  those tests unable to fail (audit tracked as #275). Same family — an assertion that cannot fail
  — different mechanism. Do not merge the two; #275 is about E2E guards, this is about Elm
  negative selectors.
- A mutation probe is the only way to prove any of these fixes. For the one already repaired,
  replacing the `readOnly` guard in `viewOrganiser` with `if False` fails both new assertions.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Test-suite integrity (meta) | yes | ⚠️ 19 sites, 1 previously disarmed and fixed; no automated guard |
| 1–13 (app/US layers) | no | n/a — no production behaviour changes |

Punch list:
1. Repoint every negative assertion that guards a **feature** onto `data-testid`. Enumerate from
   the grep above; most of the 19 are copy assertions and stay.
2. For each remaining prose negative, add (or verify) a **positive** assertion elsewhere that the
   same literal renders — that pairing is what makes a rename fail instead of silently passing.
3. Add a check that flags a `hasNot [ Selector.text … ]` whose string has a *near* match but no
   *exact* match in `frontend/src/` — the shape that disarmed the real one. Fuzzy, so expect
   false positives; an allowlist is fine. If this proves too noisy to be useful, say so and land
   items 1–2 plus a documented convention instead of shipping a check nobody trusts.

Verdict: ⚠️ — the known defect is fixed; this issue is about the class, not the instance.

## Definition of Done
- [ ] All 19 sites triaged into feature-guard vs copy-assertion — evidence: table committed here
- [ ] Every feature-guard negative anchors on `data-testid` — evidence: grep → captured output
- [ ] Every remaining prose negative has a paired positive assertion — evidence: file:line pairs
- [ ] At least one repointed assertion **mutation-probed** — evidence: the break, the failing test
      name and message, and confirmation of revert (`git diff --stat` clean)
- [ ] Convention documented in `docs/agents/standards/` (testing) — evidence: the committed diff
- [ ] Detection check landed **or** an explicit written decision that it is too noisy, with the
      reasoning — evidence: the script + its output, or the recorded decision
- [ ] `just verify` passes — evidence: command → captured output

## Progress Notes
- 2026-07-28: Found during the Wave 0 staff-campaign drive, as a side-effect of adding a
  `shelf-organiser` testId. `BookshelfReadOnlyTest`'s `no_mutation_control_SECURITY` assertion had
  been passing by matching nothing at all; it would have kept passing had the organiser leaked
  into a read-only view, which is the single thing it existed to prevent. The guard itself held
  (`viewOrganiser` returns `text ""` when `readOnly`) — only the *evidence* was missing. Fixed,
  split into two testId-anchored assertions, and mutation-probed. The sweep summarised above was
  run to find siblings; it found none live, but also demonstrated that the obvious mechanical
  check would have missed the real one. See `plans/staff-campaign-2026-07-27.md` → "A pre-existing
  SECURITY test was vacuous".
