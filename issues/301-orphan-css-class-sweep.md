# Issue #301: Sweep Elm class literals that have no CSS rule

## Summary
398 of 777 class names used in Elm views have **no matching rule** in `frontend/css/main.css`,
the only stylesheet source. Three surfaces shipped fully unstyled this way before anyone noticed.
Triage the inventory, style what should be styled, and convert pure test/JS hooks to `data-testid`.

## User Stories
None directly — this is a presentation-integrity sweep across many stories. It protects every
story with a UI surface, and it is how US-2.5.3 (`/listing-removal`), US-1.7.1 (shelf organiser)
and US-9.4.1 (profile feed link) reached a preview looking broken.

## Goal
Every class literal in `frontend/src/` either has a CSS rule behind it or is deliberately a
non-visual hook (and then it should be a `data-testid`, per project convention). The set
difference is 0 for "visual class with no rule", and a documented allowlist covers the rest.

## Scope Check
- More than 3 controllers? → No controllers; frontend-only.
- More than 2 new endpoints? → None.
- More than ~300 lines of production code? → **Yes, if done in one pass.** CSS is not
  "production code" in the risk sense, but 398 classes across ~25 component groups exceeds one
  reviewable diff. **Split per component group**, largest first: `book-detail` (45),
  `insights` (34), `profile` (15), `page` (15), `marketplace-detail` (15), `upload-verify` (12),
  `blog-post` (12), then the tail. One issue per group, or one PR per group under this issue.
- Unrelated concerns? → No.

## Wiring
Router wiring: implementation-only — no new routes or surfaces. Purely styling existing markup.

## Feature-Completeness Pre-Check
n/a — no named user stories. (The three surfaces this was discovered through are already built
and styled; see #NNN follow-ups only if triage finds an unbuilt surface behind an orphan group.)

## Technical Requirements

**Reproduce the inventory** (the numbers above are from 2026-07-28 and will drift):

```sh
grep -rhoE 'class "[^"]+"' frontend/src/ | sed 's/class "//; s/"$//' | tr ' ' '\n' \
  | grep -E '^[a-z][a-z0-9_-]*$' | sort -u > /tmp/elmclasses.txt
grep -ohE '\.[a-zA-Z][a-zA-Z0-9_-]*' frontend/css/main.css | sed 's/^\.//' | sort -u > /tmp/cssclasses.txt
comm -23 /tmp/elmclasses.txt /tmp/cssclasses.txt          # the orphans
```

- `frontend/css/main.css` is the **only** source. Everything under
  `apps/core/priv/static/assets/*.css` is build output — do not edit it, and do not count it as
  a second source when reasoning about coverage.
- **Not all 398 are defects.** A wrapper class used only as a JS or test hook needs no rule.
  Triage each into: (a) needs a rule, (b) should become a `data-testid` instead,
  (c) legitimately structural and documented.
- Follow the existing token vocabulary in `:root` (`--font-heading`, `--size-*`, `--radius-*`,
  `--shadow-*`, `--text`, `--text-muted`, `--accent`, `--shelf-bg`, `--border`) and the
  per-bookshelf theme overrides (`.shelf-library`, `.shelf-antilibrary`, …). Hardcoded hex
  values outside those tokens will look wrong under a theme switch.
- `login-card__*` is the reference pattern for a parchment form; `shelf-organiser__*` and
  `removal-queue__*` (added 2026-07-28) are the reference for a dark panel.

## Reviewer Context
- ⚠️ **This defect class is invisible to the test suite.** The classes *are* present in the DOM,
  so every `Selector.class` assertion passes. Only a `getComputedStyle` assertion or a human
  looking at the page can catch it. Do not expect a red test to justify each fix.
- `mix format` / `elm-format` do not touch CSS; the Stop hook will not catch CSS problems.
- The project has **no CSS linter**. Consider whether adding one (or a CI step running the set
  difference above with an allowlist) is in scope — that is the only thing that stops regression.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Presentation integrity (not one of the 13) | yes | ❌ no automated check exists — see punch list |
| 1–13 (app/US layers) | no | n/a — no behaviour changes; markup and behaviour are untouched |

Punch list:
1. **The set-difference check is not automated.** It was run by hand. Add it as a script
   (`scripts/check-orphan-classes.sh`) with an explicit allowlist for category (b)/(c) classes,
   so a new component cannot add an orphan silently. This is the only durable part of this issue.
2. Optionally: a smoke test asserting `getComputedStyle` is non-default for one representative
   class per component group. Cheap, and would have caught all three of the shipped-unstyled
   surfaces.

Verdict: ❌ — no coverage today; item 1 is the exit criterion that matters.

## Definition of Done
- [ ] Orphan inventory regenerated and triaged into needs-a-rule / should-be-testid / structural
      — evidence: the triage table committed in this issue, with a count per category
- [ ] Every "needs a rule" class has a rule using the `:root` tokens — evidence: set difference
      re-run → captured output showing only allowlisted classes remain
- [ ] Classes that were only test/JS hooks converted to `data-testid` — evidence: grep showing
      no remaining `class "…"` used solely by a test selector
- [ ] `scripts/check-orphan-classes.sh` exists, is wired into `just verify` (or `just ci`), and
      fails on a newly-introduced orphan — evidence: command → captured output, plus a
      deliberately-added orphan shown failing it and then removed
- [ ] Each touched surface viewed on a real stack — evidence: screenshot per component group
- [ ] Standards compliance verified (`just verify` passes) — evidence: command → captured output

## Progress Notes
- 2026-07-28: Found during the Wave 0 staff-campaign drive. `/listing-removal`, the shelf
  organiser and `profile__shelf-feed` all rendered as raw browser chrome on a preview — BEM class
  names written, zero rules behind them. Styled those three plus `admin__error` / `admin__loading`
  (already used by the existing admin pages with no rules). The sweep that produced the 398 figure
  was run to answer "how many more of these are there"; the answer is why this issue exists.
  See `plans/staff-campaign-2026-07-27.md` → "The sweep: 398 of 777 Elm class literals".
