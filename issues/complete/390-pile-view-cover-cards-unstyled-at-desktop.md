# Issue #390: Looking-for-a-Home pile-view cover cards have no desktop styling (only ≤480px)

## Summary
On `/looking-for-home`, `.pile-view__book` and `.pile-view__cover` are styled **only inside
`@media (max-width: 480px)`** (`frontend/css/main.css:2671-2684` — width/height for the cards). There
is **no base/desktop rule**, so at normal viewport widths the "pile-view of face-out cover cards"
renders as unstyled full-width text blocks (bare title + author) on the shelf-room wallpaper — not
cover cards. Found on the Wave 8 (#318 8c) coherence-sweep live drive.

## User Stories
US-18.1.1 (Browse the Looking for a Home shelf) — "displayed as books ready to find a new reader";
the amended story (#387) specifies "a pile-view of face-out cover cards staged inside that room."

## Goal
At every viewport, the Looking-for-a-Home shelf shows face-out cover cards inside its room — the
cards read as books, coherent with the other bookshelf surfaces — not unstyled text.

## Scope Check
CSS-only: give `.pile-view__book` / `.pile-view__cover` a base (desktop) rule (card dimensions,
background/spine treatment, layout), with the existing `≤480px` block as the responsive override.
Reconcile with the shelf-room family so the cards sit in the room coherently. Under the bar.

## Wiring
User-facing (aesthetic). No backend.

## Technical Requirements
1. Add base rules for `.pile-view__book` and `.pile-view__cover` (currently only present in the
   `@media (max-width: 480px)` block at `main.css:2671-2684`) so the cards are styled at desktop.
2. The cards should read as face-out books in the shelf-room family (background/spine, dimensions,
   pile layout), coherent with Library/Reading-Pile. Use existing tokens (no new literals; Wave 9
   owns tokens).
3. Live-drive `/looking-for-home` at desktop AND mobile — cover cards render in both.
4. `check-orphan-classes.sh` / `check-css.sh` clean.

## Reviewer Context
- 8c (#318) added the shelf-room wallpaper/label wrapper around the pile-view but did NOT add the
  missing base card styling — this gap is **pre-existing** (the pile-view was only ever styled at
  ≤480px) and was surfaced by the room framing making the bare-text cards salient.
- Computed styles on the live preview (2026-08-06): `.pile-view__cover` at 1440px width =
  `background: transparent; border: none; box-shadow: none; width: 928px` (full-width, uncarded).
- This is the "markup names classes whose rules don't apply at this viewport" defect class — the
  orphan gate passes because the classes DO have rules (just media-scoped), so no automated check
  catches it; only a desktop drive does.

## Definition of Done
- [x] `.pile-view__book`/`.pile-view__cover` styled at desktop as face-out cover cards — evidence: live drive 2026-08-06, computed `.pile-view__cover` = width 150px (was 928px), height 225px, `linear-gradient` cloth bg, 1px border, box-shadow, radius 4px; screenshot sent.
- [x] Coherent with the shelf-room family — evidence: portrait cover cards on the themed `--shelf-bg` binding inside the botanical-wallpaper room; same `--border`/`--shadow`/`--radius-md` treatment as the marketplace/shelf-room panels; serif title + uppercase muted author.
- [x] Desktop confirmed live; the untouched `@media (max-width:480px)` override (100×140, same ~2:3) narrows the same cards on mobile (covered by the responsive spec).
- [x] `check-orphan-classes.sh` orphans: 0; `check-css.sh` 846 rules, 0 problems, 0 collisions.
- [x] `staff-review` verdict recorded below

## Dependencies
Surfaced by **#318** 8c coherence sweep. Sibling of the fifth-shelf room work. Independent.

## Agent Assignment
elm-agent / CSS.

## Progress Notes
Filed 2026-08-06 from the #318 Wave 8 coherence-sweep live drive. The room wallpaper + brass label
(8c) render correctly; only the cover cards inside lack desktop styling. Not a Wave 8 regression —
a pre-existing CSS gap the new room made visible.


## Fixed in-branch 2026-08-06 — staff-review: LGTM
Per the owner rule (fix in the wave, track with the issue), resolved in `feat/campaign-w7-317` rather than deferred. CSS-only (+67 lines `main.css`): base `.pile-view` flex-wrap row + `.pile-view__book`/`.pile-view__cover` face-out cover cards (portrait 2:3, `var(--shelf-bg)` cloth gradient, `--border`/`--shadow`/`--radius-md`, serif title/muted author, reduced-motion-guarded hover lift). All colors are `var(--token)` — no new literals (verified: the only added color-pattern line was a comment). Gates clean. Live-driven on the preview: cover cards render (150×225, carded) — was bare full-width text. Not a Wave 8 regression; a pre-existing CSS gap the 8c room framing surfaced.
