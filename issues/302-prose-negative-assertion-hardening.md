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
- More than ~300 lines? → No. 35 call sites, most needing no change; one check script.
- Unrelated concerns? → No.

## Wiring
Router wiring: implementation-only — test-suite hardening, no user-facing surface.

## Technical Requirements

**The sweep, and how its first two conclusions were both wrong.**

The initial pass found **19** sites and concluded "no currently-live feature guard is vacuous". Both
halves were mistaken, and only building the check exposed it:

1. **19 was an undercount — the real number is 35.** The grep required `hasNot` and `Selector.text`
   on one line, but the common form spans two:
   ```elm
   |> ProgramTest.expectViewHasNot
       [ Selector.text "Add shelf" ]
   ```
   Sixteen assertions were invisible to the sweep, **including the original defect it was written to
   characterise.**
2. **Two live assertions were vacuous.** `SessionExpiryTest` asserted absence of `"signed-out"`, a
   string in no source file. `InsightsProgramTest` asserted absence of a server-supplied sentence no
   client literal could contain — so the **privacy** guarantee that risk illustrations stay hidden
   until the reader asks was guarding nothing at all.

⚠️ **And the detection rule needed to be two rules, which a probe proved.** The first version flagged
only "X is a strict substring of other copy" — and did **not** catch the reintroduced `"Add shelf"`,
because that string is not a substring of `"Add a shelf"`; it is simply *absent*. The two instances
fail in opposite directions:

| Shape | Consequence |
|---|---|
| **Matches nothing** (absent from `frontend/src/`) | Can never **fail** — the vacuous pass |
| **Strict substring** of other rendered copy | Binds to the wrong element; can never **pass** |

Worth stating plainly: only the first is vacuity. For a `hasNot`, matching *more* strings makes the
assertion **stricter**, so the substring case surfaces as a false *failure* — still a test that does
not do its job, but loud rather than silent.

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
| Test-suite integrity (meta) | yes | ✅ 35 sites checked by `scripts/check-prose-assertions.sh` in `just lint-elm`; 3 disarmed assertions found and fixed |
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
- [x] All prose negative assertions triaged — evidence: `scripts/check-prose-assertions.sh --list`
      reports **35** (not 19 — a per-line regex was missing the very common multi-line
      `expectViewHasNot` / `[ Selector.text … ]` form, including the original defect), of which 12 are
      allowlisted with reasons and the rest are safe
- [x] Every feature-guard negative anchors on `data-testid` — evidence: `BookshelfReadOnlyTest`
      `noAddShelfControl` / `noShelfOrganiserPanel` on `shelf-add` / `shelf-organiser`;
      `AdminSourceApprovalTest` on `source-approve` / `source-reject`
- [x] Two genuinely vacuous assertions found and fixed — evidence: `SessionExpiryTest` asserted
      absence of `"signed-out"` (a string in no source file) and `InsightsProgramTest` asserted a
      server-supplied sentence that no client literal could contain, so a **privacy** guarantee
      (risk illustrations hidden until the reader asks) guarded nothing. Both repointed
- [x] At least one repointed assertion **mutation-probed** — evidence: revealing the insights risk
      section alongside the gate (`Nothing -> div [] [ viewRiskGate model, viewRiskRevealed [] ]`)
      fails **exactly 1** test, the consent-gate one; reverted and 1285 green. Also probed
      `BookshelfReadOnlyTest` (`if False` on the `readOnly` guard → 2 failures)
- [x] Convention documented — evidence: `docs/agents/standards/testing.md` §"Negative Assertions —
      Anchor on `data-testid`, Never on Prose", with both failure shapes and the allowlist rule
- [x] Detection check landed and wired into the gate — evidence: `scripts/check-prose-assertions.sh`
      called from `scripts/lint-elm.sh`; probed load-bearing (breaking `"Sign Out"` → `"Sign Outt"`
      gives exit 1, reverting gives exit 0)
- [x] `just verify` passes — evidence: command → captured output (see Progress Notes)

**Not noisy enough to abandon, which the DoD allowed for:** 35 assertions → 12 needing a reviewed
reason. That is a useful signal, so the check landed rather than being dropped for a convention alone.

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
