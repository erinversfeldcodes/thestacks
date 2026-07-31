# Issue #116 — Phase 2 Complete: US-1.6.6 Reading Progress

**Committed:** 9be0c735 (issue docs) + 56000f6b (feature), feat/116-e2e
**Date:** 2026-07-23

## Delivered
- `Api.updateProgress` with typed `ProgressError`; `Components.PlacementCard` mounted on the
  Reading Pile and the Book Detail overlay per US-1.6.6 §2/§12: badge → labelled inline edit form
  → Save (disabled "Saving…" while in flight) → host folds the API response in place; the form
  stays open with the draft + an inline `role="alert"` error on failure; finishing on the Reading
  Pile surfaces the dismissible "record this read?" bridge (gated off Library books).
- Page-count ceiling in `Shelving.update_reading_progress/3` (context layer; unknown page count
  permissive by design); `placement.reading_started`/`reading_completed` registered in
  `Events.Registry` with a documented empty handler set.
- Full styling block (main.css "Reading Progress (US-1.6.6)"): card surface, 44px badge pill,
  four palette-matched status modifiers, form/error/prompt styles.

## Gate evidence
- Tests-first per layer; revision 1 = two TC WEAK cells fixed; revision 2 = ux batch (2×P1 a11y
  + 6 P2s), all verified.
- 2B-i independent runs: Elixir 2802/0, elm-test 953/0 (final); elm-review/format/make clean.
- 2B-iia skipped (no schema/proto changes). 2B-iii deferred to the Phase 5 consolidated preview gate.
- Proving gates (live): API ceiling — page 999999 on a 925-page book → 422 (the exact planning
  failure); browser — badge → save → `p. 42` renders → persists across reload → completed → bridge
  visible; rev-2 drive additionally asserted accessible names, `aria-expanded`, `role="alert"`,
  form-open-with-draft on 422. Styled-card screenshot delivered to the human.
- Reviews: elm APPROVED, elixir APPROVED, contract APPROVED, ux NEEDS_REVISION → rev-2 →
  **APPROVED**.

## Deferred findings (tracked for retro / follow-ups)
- Elm P3s: past-tense Msg naming (Dismiss*), decoder `oneOf` fail-loudly hygiene, shared
  fold/view extraction across the two hosts, ReadingPile books/cards dual source of truth
  (matters when US-1.3.2 spine progress indicator lands).
- UX: warmer bridge copy (P3-2); dead `--loading`/`--success` CSS classes; optional
  `aria-describedby` on the inline error.
- Elixir advisories: `Books.primary_edition/1` ordering nondeterminism (pre-existing),
  grandfathered over-ceiling data is a conscious write-time-guard choice, subscriber-enqueue
  cost note on empty-handler events.
- Contract P3: BookDetail dual-placement fold caveat (comment-mitigated).
