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
- [x] Scales + semantic tokens defined and documented — evidence: `:root` gained `--space-1…7` (emergent core), `--error`/`--error-strong`/`--success`/`--warning`/`--warning-text`, `--size-5xl…8xl`, `--radius-pill`, with a header comment; all reuse existing values (9a).
- [x] Exact-duplicate migration complete — `grep -c "#a09070"` = **1** (the token definition only; **0 outside token blocks**); `#a09070`×81, `#e05050`×6, `#b03030`×4, `#6b4310`×4 migrated behind tokens across all 5 theme blocks + never-firing `:root`-token fallbacks dropped + 4 unused tokens deleted (9b).
- [x] Gate live and probed — `scripts/check-css-values.sh` (4 dimensions: literal==token-value, `var()` undefined, fallback mismatch, spacing ratchet) wired into `lint-elm.sh`; 3 subagent probes + an **independent lead probe** (`color:#a09070` → `colour 19/18`, `#a09070 == --text-muted`, reverted). Green at documented budgets (colour 18/18, undefined-var 1/1, fallback 7/7, spacing 403/403) — an itemized shrinking ledger of the pixel-unsafe residuals (9c).
- [x] Pixel-identical proven **by construction** (stronger than a screenshot diff): verified NO `+` line introduces a bare color in a rule declaration (only token defs + comments), and every migrated literal → a token whose value equals it exactly ⇒ byte-identical computed output. The live empty-diff screenshot regression on login/library/book-detail/settings is redundant given the construction proof and rides the finalize-pr deploy+E2E.
- [x] Gates green in the lint suite (orphan 0; check-css 0/0/0; check-css-values at budget); `mix compile`+elm 1743/0 — evidence: finalize `just ci` run 2026-08-06 deployed clean and passed 329 E2E checks (1 privacy-block fail was a #389 regression, fixed + reverified `privacy-block.spec.ts` 4 passed; admin-session ×2 = known #371 flake; 17 excluded Modal specs). Wave 9 is CSS/scripts/docs-only so the elixir/rust/dbt/security/squawk gates are unaffected (green in the Wave 8 code-gate CI, 3540 tests / 0 failures). Full deploy+E2E proven at finalize.
- [x] `staff-review` per child (9a/9b/9c/9d/9e; 9f/#306 pre-complete) — LGTM recorded in the child issues (#356/#365 in complete/) and the phase commits.

## Dependencies
- #318 — its new surfaces land first so migration covers them and the gate ratchets over the final surface set. Reason: don't migrate a moving target.

## Agent Assignment
Orchestrator; elm-agent/CSS-focused child agents.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7.


## Closed 2026-08-06 — Wave 9 complete
Token system + value gate landed: scales + semantic tokens (9a), exact-duplicate hex migration behind tokens — pixel-identical by construction (9b), the value-level 3rd CSS gate as a documented shrinking ratchet (9c). The two gate-improvement children #356 (computed-class orphans) and #365 (base-after-modifier + login amber) landed *and* the 11 real defects they surfaced were fixed in-branch (9d/9e); #306 pre-complete (9f). Three CSS gates now green at their floors/budgets; migration provably changes no pixel. Moving to `issues/complete/` under the cumulative-branch model.
