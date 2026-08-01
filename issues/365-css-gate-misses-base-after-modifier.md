# Issue #365: Three login-card notices have never rendered their intended colour, and the CSS gate cannot see why

## Summary
Found by #360 while building the `Arrival` collapse, and **measured live rather than inferred**. In `frontend/css/main.css` the base rule `.login-card__notice` sits at **line 5860**, while its modifiers `--session-expired` (**2635**) and `--account-deleted` (**2653**) sit thousands of lines *earlier*. All three are single-class selectors, so specificity is equal `(0,1,0)` — and **later wins**. The base therefore overrides its own modifiers:

- `color` / `background` fall back to the base's accent green
- the base's `margin` / `padding` **shorthands** beat the modifiers' longhands

Measured on the running app: computed background is **`rgba(74, 124, 89, 0.15)`** — the accent green — not the declared **`rgba(184, 134, 11, 0.12)`** amber. So the amber "your session expired" and "account deleted" treatments have **never rendered on two shipped surfaces**.

## Why the gate missed it
`scripts/check-css.sh`'s check C catches base-beats-modifier **only under a pseudo-class** — the shape that cost this project seven modifiers their hover state (`.b--m` at `(0,1,0)` losing to `.b:hover` at `(0,2,0)`). The plain case, where a base rule simply appears *after* its own modifier at equal specificity, is not covered. The gate reports `0 problems` while three modifiers are inert.

This is the **sixth** gate this campaign has found reporting something other than what it means: #337 (squawk passing without reading anything), #354 (proto drift failing for harmless local staleness), the coverage gate counting generated code, #356 (orphan classes blind to computed `class (if …)`), `check-prose-assertions.sh` blind to `ensureViewHasNot`, and now this.

## Order matters here, not just specificity
Worth stating plainly because it is the trap: BEM modifiers are usually assumed to win by *convention*. They only win by *cascade order* when they follow the base. A stylesheet where modifiers are grouped by feature and bases by component will violate that silently and forever — no test can catch it, because the classes are all present and the rules all parse.

## User Stories
US-14.3.2 (session expiry notice), US-14.4.x (account deleted) — the experience half.

## Goal
The gate catches base-after-modifier at equal specificity, and the three notices render the colour they declare.

## Scope Check
One gate check + three CSS rules. ⚠️ **Generalise the check first, then fix what it finds** — repainting three rules without it just waits for the next one. Expect it to surface more than three.

## Wiring
Router wiring: none. Stylesheet + CI gate.

## Technical Requirements
1. **Generalise `check-css.sh` check C** to flag any base rule that appears *after* a modifier of the same block at equal-or-higher specificity, whether or not a pseudo-class is involved. Shorthand-versus-longhand (`margin` beating `margin-top`) must count — that is half the damage here.
2. **Measure before and after.** Report how many violations the generalised check finds. If it is more than a handful, decide with the owner whether to fix all or set a documented, shrinking budget — do **not** silently raise `budget` to make it pass, which is what turns a gate into decoration.
3. **Then repaint the three notices** so the declared amber actually renders.
4. **Verify computed style, not source order.** The acceptance evidence is `getComputedStyle` on the running app showing the amber — the same method that found this. A source-order diff proves nothing about what a browser resolves.

## Reviewer Context
- ⚠️ `frontend/css/main.css` is the **only** stylesheet source; everything under `apps/core/priv/static/assets/` is build output.
- ⚠️ #360 deliberately left this unrepainted under scope-lock, and its own new rule declares only `cursor` and `text-decoration` — properties the base does not set — which it verified apply live. Do not undo that care.
- ⚠️ Related gate work: **#356** (orphan gate blind to computed classes) touches the same family of "the classes are present so no test can catch it" defects. Consider whether the two gates should be fixed together.
- The seven-modifier hover incident is the precedent for why this gate exists at all — read `check-css.sh`'s header before editing it.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| CI/gate | yes | ❌ counterfactual: a base rule placed after its modifier at equal specificity fails the gate (passes today) |
| CI/gate | yes | ❌ the existing pseudo-class case still caught; no regression in the seven-modifier protection |
| Visual | yes | ❌ `getComputedStyle` shows the declared amber on both shipped surfaces |
| Others | no | n/a |

## Definition of Done
- [ ] Check C generalised; shorthand-vs-longhand counted — evidence: diff + counterfactual transcript
- [ ] Violation count reported and dispositioned (no silent budget raise) — evidence: the number + decision
- [ ] Three notices repainted — evidence: computed-style readings, before and after
- [ ] `check-css.sh` green at the agreed budget — evidence: output
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by **#360**. Related to **#356**. Needs an owner wave assignment — Wave 9 (token system + value gate) is the natural home, since it already owns the third CSS gate.

## Agent Assignment
elm-agent / design.

## Progress Notes
Filed 2026-08-01 by the lead from #360's out-of-scope finding. The agent measured the computed background live (`rgba(74, 124, 89, 0.15)` where `rgba(184, 134, 11, 0.12)` was declared) rather than reasoning from source order, which is what makes this actionable rather than speculative.
