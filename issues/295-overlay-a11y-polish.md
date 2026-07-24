# Issue #295: Book Detail Overlay A11y/Code Polish (P3 batch from #114 reviews)

## Summary
Non-blocking P3 advisories deferred from #114's reviews (2026-07-24): (a) consider focusing the dialog card (which carries `aria-label "Book details: {title}"`) instead of the Close button on open — better first utterance for a reading-first overlay (WAI-ARIA APG allows container focus); (b) the Remove-success path navigates to `previousRoute` with no focus target, dropping keyboard/SR focus to `<body>` — focus a destination landmark; (c) dead CSS: `.book-overlay__close` (main.css:3365) styles a block button while the view renders the round "×" inline — remove or reconcile; (d) add a one-line defense-in-depth comment at the unreachable `resolve_visibility == :hidden → 404` branch (book_controller.ex:211).

## User Stories
- US-1.4.1 — Open a Book's Detail Overlay (polish slice; core a11y shipped in #114)

## Goal
The overlay's keyboard/SR experience is refined end-to-end (open utterance, post-remove focus) and the two code-hygiene notes are resolved.

## Scope Check
All four checks: No.

## Wiring
Router wiring: n/a — polish of existing UI.

## Feature-Completeness Pre-Check
n/a-adjacent — polish of a shipped story; fill hops for changed affordances when picked up.

## Technical Requirements
- (a) Main.elm open-focus target: card (`tabindex -1`, labelled) vs `book-overlay-close` — decide with a quick SR check; update the E2E focus-on-open assertion in lockstep (book-detail.spec.ts:182).
- (b) Remove-success (`BookDetail.elm:431-437` → Main.elm:2098-2101): set a focus target on the destination shelf (heading/landmark).
- (c) Remove/reconcile the dead `.book-overlay__close` rule (main.css:3365).
- (d) One-line comment at book_controller.ex:211.

## Reviewer Context
- The #114 E2E suite asserts the current focus-on-open target — change (a) must update that spec in the same diff.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 10 (Elm) + E2E | yes | ❌ focus-target assertions per (a)/(b) → ✅ when done |
| others | no | n/a — polish only |

## Definition of Done
- [ ] (a) decided + implemented + E2E updated — evidence: spec diff + live SR/keyboard note
- [ ] (b) post-remove focus target set — evidence: program/E2E assertion
- [ ] (c) + (d) applied — evidence: diff
- [ ] `just verify` passes; **`completion-audit` passed**

## Dependencies
- #114 (shipped overlay a11y this polishes).

## Agent Assignment
`elm-agent` (+ `ux-reviewer` advisory).

## Progress Notes
- 2026-07-24 — Created from #114 review P3 batch (ux ×2, ux-cosmetic ×1, elixir ×1).
