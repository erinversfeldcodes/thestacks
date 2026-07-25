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
- (e) Full-page BookDetail route: keyboard Escape does not dismiss the remove modal (Main's global Escape only forwards into BookDetail when the overlay is open; on the page route it falls through to user-menu-close). Pre-existing, found in the #114 ux re-review 2026-07-24. Fix: forward Escape to the page-route BookDetail too (same consumed/not-consumed OutMsg pattern).

## Reviewer Context
- The #114 E2E suite asserts the current focus-on-open target — change (a) must update that spec in the same diff.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 10 (Elm) + E2E | yes | ❌ focus-target assertions per (a)/(b) → ✅ when done |
| others | no | n/a — polish only |

## Definition of Done
- [x] (a) decided + implemented + E2E updated — evidence: focus-on-open now targets the labelled dialog card (`BookDetail.cardFocusId = "book-overlay-card"`, `Main.openOverlayWithTrigger` focuses it); program test `cardExposesFocusOnOpenTarget` (id + tabindex -1 + aria-label); E2E `book-detail.spec.ts:186` (card focus on open) + `:199` (first Tab from card → close button) — live 27/27. SR/keyboard note: the card carries `aria-label "Book details: {title}"` so a reader announces the book first on open; being `tabindex -1` it is out of the tab order, so the first forward Tab reaches the close button and the close↔sentinel trap is unchanged.
- [x] (b) post-remove focus target set — evidence: `Main.focusMainContent` fires on the remove-success `NavigateTo` (both overlay + full-page handlers); `main-content` landmark given `tabindex -1` so focus lands; E2E `book-detail.spec.ts:520` "removing the book returns focus to the main landmark" — live pass. (BookDetail-side `NavigateTo previousRoute` already covered by `removeConfirmNavigatesToPreviousRoute`.)
- [x] (c) + (d) applied — evidence: (c) removed dead `.book-overlay__close` block + `:hover` (belonged to the removed Library quick-view block-button; only bled margin/padding onto the inline-styled round "×") in `main.css`, kept the live `.book-overlay__close:focus-visible` ring; (d) one-line defense-in-depth comment at `book_controller.ex:211`.
- [x] (e) page-route Escape forwarding — evidence: `Main.EscapePressed` `Nothing` branch now forwards to `PageBookDetail` (same consumed/not-consumed pattern); E2E `book-detail.spec.ts:545` "Escape dismisses the remove modal on the full-page route" — live pass.
- [x] `just verify` passes; **`completion-audit` passed** — evidence: `just verify` green on branch tip 2026-07-25 — elixir 2931 tests/0 failures, elm 1056/0, dbt 237/237 (scratchpad/verify-head-post284.log; sources.yml gap it caught fixed in 6fbe066c); epic completion-audit PASS 2026-07-25 — adversarial spot-verification of all 16 children found zero false evidence tokens; its 3 finalization blockers cleared (CVE fix 32b2a18c + ci green, compact audits 8eaf4bb6, preview E2E below)

## Dependencies
- #114 (shipped overlay a11y this polishes).

## Agent Assignment
`elm-agent` (+ `ux-reviewer` advisory).

## Progress Notes
- 2026-07-24 — Created from #114 review P3 batch (ux ×2, ux-cosmetic ×1, elixir ×1).
- 2026-07-24 — Implemented all five items (a)-(e). Test-first: `cardExposesFocusOnOpenTarget` captured failing-first at the elm-test layer (`Query.find [id "book-overlay-card"]` → 0 matches; baseline 1031 pass + 1 fail) before adding the card `id`. Items (b)/(e) are Main-level wiring (not program-testable in isolation) so their new post-conditions are proven by the live E2E specs, which are non-vacuous: without `focusMainContent` post-remove focus falls to `<body>` (not `main-content`), and without the page-route Escape forwarding the modal stays open (the old `Nothing` branch only closed the user menu). Gates: elm-test **1032/0** (baseline 1031 + card test); elm-format `--validate` clean; elm-review no errors; vacuous-guard check clean; E2E `book-detail.spec.ts --project=chromium` **27/27** live on :4000; scoped `book_controller_test.exs` **41/0** (comment-only). Full `just verify` + `completion-audit` left for the integration gate.
