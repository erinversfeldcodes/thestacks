# Issue #319: [EPIC] Campaign Wave 9 — Token system + value gate

## Summary
Epic for Wave 9 of `plans/staff-campaign-2026-07-30.md`: complete the design-token system and gate it at the VALUE level. The two structural CSS gates closed the orphan-class problem (398→0); token values remain ungoverned: 272 hardcoded hex, zero spacing tokens vs 516 literals, no semantic state tokens, drift accelerating in the newest surfaces.

## User Stories
None directly — the design-system layer every US renders through. Validation = the new gate + visual regression on exemplar surfaces.

## Goal
A spacing scale exists and new code must use it; semantic state tokens exist (one error red, not two); the type scale covers display sizes; exact-duplicate hex literals are migrated; a third CSS gate fails the build on new value-level drift.

## Scope Check
Epic; migration children batched by token dimension (colour / spacing / type / radius+shadow), each mechanical.

## Wiring
Router wiring: none — `frontend/css/main.css` + the gate script.

## Feature-Completeness Pre-Check
n/a — no user stories.

## Technical Requirements (child phases)
1. **Scales**: spacing tokens (base-4 or matching the emergent 0.5/0.75/1/1.5rem core — 53% of the 516 literals already fit); semantic state tokens (`--error` consolidating `#e05050`/`#b03030`, `--success`, `--warning`); type-scale extension past `--size-4xl: 2.5rem` (display sizes are all off-scale today because the scale stops short); `--radius-pill`; document the scale in the CSS header.
2. **Migration**: the 9 exact-duplicate hex values (97 occurrences — `#a09070`×71 first); the 10 near-duplicates (23 occ — four separate near-misses of `--parchment-dark` alone); fix the 10 fallback/definition mismatches; delete or adopt the 5 defined-but-unused tokens (`--shelf-text` declared in all five themes, read by nothing); theme-scoped values un-baked from unscoped rules (`main.css:4380-4381`).
3. **The third gate**: `scripts/check-css-values.sh` (or extend `check-css.sh`) failing on: a literal equal to an existing token's value, `var()` of an undefined token, a fallback disagreeing with the token's definition, and (ratchet, then floor) new spacing literals once the scale exists. Wire into the Stop-hook suite beside the other two gates.
4. **Rules**: indicators never `transition` (login tab + progress dot precedent); no `transition: all`; anything state/network-dependent gets its space reserved by layout (the shift class from register + upload) — written into `docs/agents/standards/code-quality.md`'s CSS section.

## Reviewer Context
- Both existing gates sit at zero-budget floors; the new gate starts as a ratchet (current-count budget) and ratchets to zero per dimension — mirrors how the orphan gate landed.
- 5 theme blocks redefine the palette — migrations must edit every theme block or the theme system silently forks (the `#2c3e55` bake-in is the cautionary example).
- Spacing has ZERO adoption — greenfield; colour is 57% adopted — ratchet.
- Do not restyle surfaces here (that was #318); this wave only moves values behind tokens — pixel-identical output, verified by screenshot diff on exemplar pages.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Gate | yes | ❌ probe: adding `color: #a09070` fails the build; `var(--nonexistent)` fails; mismatched fallback fails |
| Visual regression | yes | ❌ before/after screenshot pairs on login, library, book detail, settings — pixel-identical (or intentionally-changed list) |
| 1–13 | no | n/a — value migration |

Punch: gate probes ×3 + screenshot pairs ×4.
Verdict: baseline ❌.

## Definition of Done
- [ ] Scales + semantic tokens defined and documented — evidence: main.css diff
- [ ] Exact-duplicate migration complete: `grep -c "#a09070"` = 0 outside token blocks — evidence: command→output
- [ ] Gate live and probed (3 probe transcripts) — evidence: transcripts
- [ ] Visual regression pairs captured, differences enumerated — evidence: screenshot set
- [ ] `just verify` green (gates in the hook suite); audit GREEN; `completion-audit`; Completion Bar (drive = the regression pairs)
- [ ] `staff-review` per child in Progress Notes

## Dependencies
- #318 — its new surfaces land first so migration covers them and the gate ratchets over the final surface set. Reason: don't migrate a moving target.

## Agent Assignment
Orchestrator; elm-agent/CSS-focused child agents.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7.
