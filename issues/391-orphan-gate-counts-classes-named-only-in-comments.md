# Issue #391: The orphan-class gate counts classes named only in CSS comments as "defined"

## Summary
`scripts/check-orphan-classes.sh` extracts the "defined" CSS-selector set from raw `main.css`
**without stripping comments** (unlike `scripts/check-css-values.sh`, which strips them before its
scan). So a class name appearing only in prose — e.g. `.admin__error` in a `/* mirror of … */`
comment — counts as "defined" and can **mask a real orphan** (a class used in Elm with no actual
rule). Surfaced by the Mode B staff-review of Wave 9 (2026-08-06).

## User Stories
None — CSS-gate hygiene (the design-system governance layer).

## Goal
The orphan gate's "defined" set is built from real CSS selectors only, so a class mentioned only in
a comment cannot mask an orphan; the two CSS gates agree on treating comments as non-code.

## Scope Check
One script: strip CSS comments before the selector extraction in `check-orphan-classes.sh` (reuse
the comment-strip approach `check-css-values.sh` already uses). Under the bar.

## Wiring
Tooling only. No app change.

## Technical Requirements
1. Strip `/* … */` comments from `main.css` before harvesting the `defined` selector set (mirror
   `check-css-values.sh`'s stripper so the two gates are consistent).
2. ⚠️ **This may surface NEW orphans** that were being masked by comment-mentions (the review named
   `.admin__error` as a candidate). Report them and disposition each (add a rule / real orphan → fix
   or hook-exempt) — do NOT auto-suppress or raise the budget silently. That downstream work is the
   reason this is tracked rather than force-fixed inside Wave 9.
3. Gate stays exit-0 when clean; the newly-surfaced orphans are dispositioned before it lands green.

## Reviewer Context
- The fix is small; the RISK is the masked orphans it exposes — treat those like #356's surfaced set
  (surface, disposition, don't suppress).
- `check-css-values.sh:60` is the comment-strip precedent to copy.

## Definition of Done
- [x] Comments stripped before the `defined` extraction — evidence: `8ca3b2fd`, probed at landing (comment-only class no longer counts as defined)
- [x] Newly-surfaced orphans reported and each dispositioned — evidence: the strip surfaced ZERO new orphans (gate green 0 immediately after)
- [x] `check-orphan-classes.sh` green — evidence: 2026-08-09 lint-elm run: "Elm classes: 882 CSS selectors: 953 orphans: 0"
- [x] `staff-review` verdict recorded below — see Wave 11 close-out

## Dependencies
Surfaced by the Wave 9 (#319) Mode B review. Sibling of #356/#365 (CSS-gate hardening). Independent.

## Agent Assignment
Tooling / CSS.

## Progress Notes
Filed 2026-08-06 from the Wave 9 Mode B staff-review's 🟨 finding. Pre-existing (not a Wave 9
regression); deferred rather than force-fixed because it likely surfaces masked orphans that need
their own disposition. Assigned to **Wave 11** (launch-gate hardening, with the other gate/test items).


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM** — comment-stripping before extraction is the general fix, not a special case; gate green 0 orphans after.
