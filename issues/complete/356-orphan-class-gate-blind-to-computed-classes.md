# Issue #356: The orphan-class gate cannot see a computed `class (…)` expression

## Summary
Found by the lead's Wave 5 live drive, 2026-07-31, after the shelf-choice buttons rendered as **white bars with black text** against the dark-academic theme — while `scripts/check-orphan-classes.sh` reported **`orphans: 88 (0 unstyled)`**.

The gate extracts class literals with:

```python
re.findall(r'class\s+"([^"\n]+)"', text)
```

That requires a string literal **immediately** after `class`. It therefore sees `class "foo"`, and is blind to the conditional form Elm uses whenever a class depends on state:

```elm
class
    (if shelf.value == selectedShelf then
        "upload-shelf-picker__shelf upload-shelf-picker__shelf--selected"
     else
        "upload-shelf-picker__shelf"
    )
```

Here `class` is followed by `(`, so **none** of those literals enter the `used` set — and a class that is never *used*, as far as the gate knows, can never be *orphaned*.

**Measured scale: 42 computed `class (…)` constructs across `frontend/src`.** Every class named only inside one is invisible to the gate, and selected/active-state modifiers are exactly the classes most likely to appear there.

## The defect it hid
`.upload-shelf-picker__shelf` and `.upload-shelf-picker__shelf--selected` have **no rule in `frontend/css/main.css` and never have** (`git log -S` over the stylesheet returns nothing; the class arrived in "feat: upload verification step with shelf picker"). The container `.upload-shelf-picker__shelves` *is* styled — and still carries `list-style: none`, from when these were `<li>`s rather than `<button>`s — so the group lays out correctly while every item in it renders as an unstyled native button.

⚠️ **Pre-existing, not introduced by Wave 5** — but Wave 5 made it prominent: #343 put `viewShelfChoices` on the **manual ISBN path**, so it is now the first thing a reader sees when adding a book by number, not just a step inside the photo flow.

## Why this matters beyond one component
This project added the orphan gate precisely because *"markup naming a style that doesn't exist is its own defect class — no test can catch it, since the classes **are** present"*, after three surfaces shipped fully unstyled. A gate with a 42-site blind spot in exactly the state-dependent classes most likely to be styled distinctly is not doing the job it was built for — and its clean `0 unstyled` reading is actively reassuring while the defect ships.

This is the **fourth** gate this campaign has found reporting something other than what it means: #337 (squawk passes without reading anything), #354 (proto drift fails for harmless local staleness), the coverage gate counting generated code as untested product code (fixed in Wave 4), and now this.

## User Stories
None — tooling correctness. Validated by the counterfactual below.

## Scope Check
One Python-in-shell extractor, plus whatever CSS the newly-visible orphans turn out to need. ⚠️ **Expect the orphan count to jump** once the blind spot closes — that is the point, but it means the CSS work is unbounded until measured. **Measure first, then decide whether the CSS is this issue or a follow-up.**

## Wiring
Router wiring: none. CI/gate surface, plus stylesheet.

## Technical Requirements
1. **Extract computed class expressions.** Handle at least `class (if … then "a" else "b")`, `classList [ ("a", cond) ]`, and `class (… ++ …)`. A pragmatic approach: within a `class`/`classList` application, collect **all** string literals up to the closing delimiter, rather than requiring one immediately. Perfect Elm parsing is not required — over-collecting class-shaped tokens is safe here, since a false "used" entry can only *add* an orphan to investigate, never hide one.
2. **Measure before fixing CSS.** Report the orphan count before and after the extractor change. The current budget is `ORPHAN_BUDGET=0` with 88 hook-exempt classes; closing the blind spot will surface more, and some will be genuine hooks. Do not raise the budget to make it pass — triage each.
3. **Style `.upload-shelf-picker__shelf` / `--selected`.** ⚠️ **Design is the owner's call** — match an existing sibling pattern rather than inventing a look, and confirm before shipping anything novel. Note the stale `list-style: none` on the container, from when these were list items.
4. **Counterfactual acceptance test.** Add a class inside a computed `class (…)` with no CSS rule; the gate must fail. Quote both transcripts (passes today, fails after). This is the #330 precedent.

## Reviewer Context
- ⚠️ `frontend/css/main.css` is the **only** stylesheet source; everything under `apps/core/priv/static/assets/` is build output. Do not edit build output.
- ⚠️ **Not every orphan is a defect** — a class used only as a unit-test or E2E selector is a legitimate hook and the script already exempts verified ones (`--hooks`). Keep that distinction; do not exempt something merely because styling it is inconvenient.
- ⚠️ `scripts/check-css.sh` is the sibling specificity gate (`.b--m` at (0,1,0) losing to `.b:hover` at (0,2,0) cost this project seven modifiers). Run both.
- Related gate-truthfulness work: **#337**, **#354**, **#334**.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| CI/gate | yes | ❌ counterfactual: an unstyled class inside a computed `class (…)` fails the gate (passes today) |
| CI/gate | yes | ❌ hook exemptions still honoured; budget still 0 |
| Visual | yes | ❌ the shelf buttons render in-theme — screenshot, since this is an appearance defect and only a drive can settle it |
| Others | no | n/a |

## Definition of Done
- [x] Extractor handles computed class forms — evidence: diff
- [x] Before/after orphan counts reported and each new orphan triaged — evidence: the numbers + dispositions
- [x] Counterfactual red — evidence: both transcripts
- [x] Shelf buttons styled in-theme, design confirmed with the owner — evidence: screenshot
- [x] `check-css.sh` clean — evidence: output
- [x] `staff-review` verdict recorded below

## Dependencies
None. Surfaced by the Wave 5 live drive. Needs an owner wave assignment.

## Agent Assignment
elm-agent + design review.

## Progress Notes
Filed 2026-07-31 by the lead. Verified by running the gate's own regex against `Page/Upload.elm`: `upload-shelf-picker__shelf` is **not** extracted, and `grep -cE "\.upload-shelf-picker__shelf[^a-z-]" frontend/css/main.css` → **0**. Repo-wide count of computed `class (…)` constructs: **42**.

## Partial fix landed 2026-07-31 — the CSS, not the gate
The owner asked for the visual defect to be fixed during the Wave 5 close, with **"a distinct un/selected treatment that is compatible with the rest of the aesthetic"**. Done in `frontend/css/main.css` beside `.upload-shelf-picker__shelves`:

- **Unselected** recedes — transparent fill, `var(--border)` hairline, `var(--text-muted)`, normal weight.
- **Selected** advances — `rgba(74, 124, 89, 0.22)` fill, `var(--accent)` border, `var(--text)`, weight 600.
- The two states differ in **three channels** (fill, border, weight/colour) rather than hue alone, so the choice stays legible to a reader who cannot distinguish the green.
- ⚠️ `.upload-shelf-picker__shelf--selected` is listed **with `:hover`** deliberately: bare, it is (0,1,0) and loses to `.upload-shelf-picker__shelf:hover` at (0,2,0) — the specificity trap that once cost this project seven modifiers their state on hover. Pointing at a chosen shelf must not make it look unchosen.

Verified on the live preview by injecting the exact rules and reading **computed** styles rather than eyeballing a screenshot:
```
selected   bg rgba(74,124,89,0.22)  border rgb(74,124,89)      color rgb(232,220,200)  weight 600
unselected bg rgba(0,0,0,0)         border rgba(255,255,255,.1) color rgb(160,144,112)  weight 400
```
Counterfactual: removing the injected rules reverts the button to `rgb(239,239,239)` — native grey — confirming the deployed build has no rule and this CSS is what fixes it. `check-css.sh` 732 rules / 0 problems / 0 collisions; `lint-elm.sh` clean.

**⛔ The gate itself is still blind — this issue remains OPEN for that.** Requirements 1, 2 and 4 are untouched: the extractor still cannot see the 42 computed `class (…)` constructs, so the next class named only inside one will ship unstyled exactly as this one did. Fixing the symptom while the detector stays blind is the smaller half of the work.

**CSS fix confirmed on the deployed build 2026-07-31** (`stacks-core-pr-feat-campaign-followups-a`) — not an injection this time. The shelf choices render from the shipped stylesheet: unselected recede (transparent, hairline border, muted text), the selected one carries the accent fill and border with bold cream text. Screenshot in the batch record. The gate half of this issue remains open.


## Fixed in-branch 2026-08-06 — staff-review: LGTM
`check-orphan-classes.sh` now harvests string literals inside computed `class (...)` / `classList [...]` forms (balanced, string-aware; drops concat-prefix tokens ending in `-`/`_`). Counterfactual: the OLD regex can't see `class (if … "…-probe")`; the NEW gate reds on it (both transcripts captured, probe reverted). `used` 854→882; it surfaced **5** classes the old gate was structurally blind to, all dispositioned (NOT suppressed, budget stayed 0):
- `tab`/`tab--active` (Groups tabs) and `marketplace__status-badge`/`__condition-badge` — genuine unstyled surfaces → **styled in-wave matching existing siblings** per owner ruling (2026-08-06): tabs mirror `.login-card__tab`, badges mirror the `.rss-link__icon` inline-badge pattern; tokens-only, no new literals; the `.tab--active:hover` specificity trap handled via the existing `--active:hover` precedent.
- `app-nav__item` — rule-less by design → documented no-op rule (`list-style:none`, styling lives on the child link), the `.user-menu__backdrop` precedent.
Both gates back to zero (orphans 0; check-css 0/0/0). Wave 9 (9d).
