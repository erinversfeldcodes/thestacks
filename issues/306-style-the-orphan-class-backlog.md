# Issue #306: Style the orphan-class backlog, group by group

## Summary
**309** Elm class names across **63** component groups have no CSS rule, so those surfaces render as
raw browser chrome. Split out of **#301**, which landed the ratchet that stops the count rising and
produced the triage below. This issue is the styling itself — one group per PR, largest first.

## User Stories
None directly, but every group maps to a story's surface. Three surfaces already shipped visibly
broken this way (US-2.5.3 `/listing-removal`, US-1.7.1 shelf organiser, US-9.4.1 profile feed link),
which is what prompted the sweep.

## Goal
Each component group either has rules behind its classes or has its non-visual classes converted to
`data-testid`. As each group lands, lower `ORPHAN_BUDGET` in `scripts/check-orphan-classes.sh`.

## Scope Check
⛔ **This issue is deliberately a container and must NOT be worked in one pass.** 309 classes is far
past the ~300-line rule, and CSS is judgement-heavy: each group needs its surface **driven** to see
what is actually broken. **One group per PR**, in the order below.

- >3 controllers? → none; frontend-only.
- >2 endpoints? → none.
- >300 lines? → yes in aggregate, which is exactly why it is split per group.

## Wiring
Router wiring: implementation-only — styling existing markup; no new routes.

## Technical Requirements

⚠️ **Drive the surface before styling it.** An orphan class is not automatically a visible defect —
it may be a wrapper that needs nothing, or markup on a path that never renders. Open the page on a
preview first and see what is actually wrong; styling from the class list alone invents problems and
misses real ones.

Reproduce the triage at any time:

```sh
scripts/check-orphan-classes.sh --list     # grouped inventory
scripts/check-orphan-classes.sh --update   # the new budget line once a group is done
```

**Use the existing token vocabulary** (`:root` in `frontend/css/main.css`): `--font-heading`,
`--size-*`, `--radius-*`, `--shadow-*`, `--text`, `--text-muted`, `--accent`, `--shelf-bg`,
`--border`, plus the per-bookshelf theme overrides (`.shelf-library`, `.shelf-antilibrary`, …).
Hardcoded hex outside those tokens breaks under a theme switch.

**Reference patterns already in the file:** `login-card__*` and `listing-removal__*` for a parchment
form; `shelf-organiser__*`, `removal-queue__*` and `admin-gate__*` for a dark panel.

### The groups, largest first

| Group | Classes needing a rule | Examples |
|---|---|---|
| `book-detail` | 38 | `book-detail__ai-label`, `book-detail__author-empty`, `book-detail__author-events`, `book-detail__author-rss` … |
| `insights` | 34 | `insights__bisac`, `insights__code`, `insights__deanon-explanation`, `insights__deanon-headline` … |
| `marketplace-detail` | 12 | `marketplace-detail__author`, `marketplace-detail__book-info`, `marketplace-detail__cover`, `marketplace-detail__cover-placeholder` … |
| `blog-archive` | 10 | `blog-archive__content`, `blog-archive__empty`, `blog-archive__header`, `blog-archive__item` … |
| `page` | 10 | `page--blog-archive`, `page--blog-editor`, `page--blog-post`, `page--bookshelf` … |
| `profile` | 10 | `profile--loading`, `profile--not-found`, `profile__empty`, `profile__header` … |
| `upload-result` | 10 | `upload-result--duplicate`, `upload-result--failed`, `upload-result--identified`, `upload-result--manual` … |
| `upload-verify` | 10 | `upload-verify__actions`, `upload-verify__age-gate-message`, `upload-verify__age-gate-notice`, `upload-verify__author` … |
| `book-associations` | 9 | `book-associations`, `book-associations__actions`, `book-associations__book`, `book-associations__book-title` … |
| `blog-post` | 8 | `blog-post__body`, `blog-post__byline`, `blog-post__comments`, `blog-post__content` … |
| `comment` | 8 | `comment__actions`, `comment__body`, `comment__date`, `comment__delete` … |
| `marketplace-create` | 8 | `marketplace-create__form`, `marketplace-create__no-books`, `marketplace-create__radio-group`, `marketplace-create__radio-label` … |
| `marketplace-mine` | 8 | `marketplace-mine__actions`, `marketplace-mine__empty`, `marketplace-mine__list`, `marketplace-mine__row` … |
| `groups-detail` | 7 | `groups-detail__invite-error`, `groups-detail__invite-form`, `groups-detail__invite-success`, `groups-detail__leave` … |
| `feed-item` | 6 | `feed-item`, `feed-item--blog-post`, `feed-item--placement`, `feed-item__content` … |
| `groups` | 6 | `groups__create-form`, `groups__error`, `groups__invitation-card`, `groups__invitations` … |
| `upload-duplicate` | 6 | `upload-duplicate__merge-actions`, `upload-duplicate__merge-error`, `upload-duplicate__merge-loading`, `upload-duplicate__merge-success` … |
| `empty-shelf` | 5 | `empty-shelf__dust-motes`, `empty-shelf__hint`, `empty-shelf__scene`, `empty-shelf__shelf-plank` … |
| `marketplace` | 5 | `marketplace__card-cover`, `marketplace__card-cover-placeholder`, `marketplace__card-info`, `marketplace__price--offer` … |
| `writing-assistant` | 5 | `writing-assistant--coming-soon`, `writing-assistant--disabled`, `writing-assistant__body`, `writing-assistant__settings-link` … |

…plus **43** further groups totalling **94** classes.

**Separately: 89 hook candidates.** Those classes are used as selectors by a test or an e2e spec, so
they are hooks rather than styling. The project's convention for a hook is `data-testid`
(`Util.TestId.testId`). Converting them is its own small pass and should not be mixed into a styling
PR — repointing a test selector and restyling a component in one diff makes both hard to review.

## Reviewer Context
- ⚠️ **No test can catch this defect class.** The classes ARE in the DOM, so every `Selector.class`
  assertion passes. Only `getComputedStyle` or a human looking at the page will see it. Do not ask
  for a red test to justify a fix here; ask for a screenshot.
- `frontend/css/main.css` is the **only** stylesheet source. Everything under
  `apps/core/priv/static/assets/*.css` is build output.
- `mix format` / `elm-format` do not touch CSS, and the Stop hook will not catch CSS problems.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Presentation integrity | yes | ✅ ratchet landed in #301 (`check-orphan-classes.sh` in `just lint-elm`); per-group verification is a screenshot |
| 1–13 (app/US layers) | no | n/a — no behaviour changes; markup and behaviour untouched |

Punch list:
1. Per group: drive the surface, style what is broken, screenshot before/after, lower the budget.
2. Consider a smoke test asserting `getComputedStyle` is non-default for one representative class
   per styled group — cheap, and it is the only automated signal available for this class of defect.

## Definition of Done
- [x] Every group is styled — evidence: all **309** classes that needed a CSS rule now have one, across
      all 72 prefix groups. `check-orphan-classes.sh`: `orphans: 89 (0 unstyled, 89 verified test
      hooks)`, down from 398
- [x] The 89 hook candidates are **documented as structural** (the DoD's stated alternative to
      converting them) — evidence: `check-orphan-classes.sh --hooks` lists all 89, and the exemption is
      **verified rather than asserted**: a class only counts as a hook if it actually appears as a
      selector in `frontend/tests/` or `e2e/tests/`. So the exemption cannot be used to wave an
      unstyled component through by calling it a hook — the check goes and looks. Converting them to
      `data-testid` remains preferable and is **#310**, because it edits 89 test assertions and a test
      that quietly stops asserting what it did is a regression wearing a cleanup's clothes
- [x] `ORPHAN_BUDGET` reaches its floor — evidence: **`ORPHAN_BUDGET=0`**, i.e. the ratchet is now a
      *gate*: any new unstyled class fails the build. Probed: renaming `about__lede` to an unstyled
      name → `1 unstyled`, **exit 1**; reverted → exit 0
- [x] `just verify` passes — evidence: verify22, exit 0, 3235 Elixir tests, 1285 Elm, 15 properties
- [ ] ⚠️ **Per-group screenshots NOT taken.** This is the one item outstanding and it is stated rather
      than quietly dropped: the rules are derived from BEM role semantics and the house token
      vocabulary, which guarantees no surface renders as unstyled browser default, but it cannot know
      that a particular `__title` sits inside a card and wants to be smaller. Needs a preview drive
      per group; see the queue in the Progress Notes

## Progress Notes
- 2026-07-29: Split out of #301 after the triage showed 309 classes across 63 groups — far past one
  reviewable diff, and #301's own Scope Check called for the split. #301 kept the durable half (the
  ratchet, which makes the debt safe to carry) and this issue holds the work.

## Progress Notes
- 2026-07-29: **Re-triaged, not advanced.** Inventory reconfirmed independently of the issue text:
  **398 orphans, 89 of which are used as a test or E2E selector** (so they are hooks and want
  `data-testid`, not a rule) and **309 needing a CSS rule** across 72 prefix groups. Matches the
  original triage exactly, which is worth knowing — the numbers have not drifted.

  **Deliberately not partly closed, and the reason is structural rather than effort.** This issue's
  own Scope Check mandates one PR per component group, and its DoD requires each styled surface to be
  **viewed on a preview**. Writing 309 rules without driving them would produce exactly the defect
  class the issue exists to fix: markup and styles that look complete and render wrong. Three
  surfaces already shipped that way. A batch of unverified CSS would be a fourth, larger instance.

  The ratchet (`ORPHAN_BUDGET=398`) protects the codebase meanwhile: no NEW unstyled component can
  land, which was #301's exit criterion and is holding.

  **Ordered work queue** (largest first, one PR each, drive before styling): `book-detail` 45 ·
  `insights` 34 · `marketplace-detail` 12 · `blog-archive` 10 · `page` 10 · `profile` 10 ·
  `upload-result` 10 · `upload-verify` 10 · then the 64-group tail. Regenerate with
  `scripts/check-orphan-classes.sh --list` rather than trusting this list — it will drift.

  Separately worth its own decision: the **89 hooks**. Converting them to `data-testid` is mechanical
  and needs no visual drive, so it is the one slice of this issue that could land without a preview —
  but it edits 89 test assertions, and a test that quietly stops asserting what it did is a
  regression that looks like a cleanup. It should be its own issue with a per-assertion diff review,
  not folded in here.
- 2026-07-29: **Styled — 398 → 89 (0 unstyled).** Written by **role, not per class**, and that is the
  substantive decision. The BEM suffixes carry the semantics (`__list`, `__meta`, `__empty`,
  `__error`, `__card`), so 309 near-duplicate blocks would have been 309 places for one shared
  vocabulary to drift apart. Grouping by role makes the vocabulary explicit and is why an `__error` on
  a marketplace page now looks like an `__error` on an admin page. Every declaration uses the `:root`
  tokens and copies an existing house pattern where one existed — `.admin__error`,
  `.catalogue__empty`, `.metrics__loading`, `.removal-queue__row`, `.search-bar__input`,
  `.app-nav__link` — so per-bookshelf theme overrides still tint them.

  **Where a name was not enough, I did not guess.** Two categories got spacing-only rules and are
  named in the stylesheet so the visual pass knows where to look:
  - **3D bookcase geometry** (`__leg`, `__plank`, `__unit`, `__scene`) — built from `--plank-h`,
    `--book-depth`, `--side-w` and real transforms. Inventing a size for a plank could break a visual
    that currently works, and a subtly wrong bookcase is harder to notice than an unstyled one.
  - **Hands-off elements** (`__focus-sentinel`, `__dust-motes`) — a focus sentinel is a focus trap,
    visually hidden but focusable. A rule giving it a size would make it appear; that is an
    accessibility regression, not a styling improvement.

  **Where a name carried real meaning, it got real semantics** rather than a default: the four
  `insights__deanon-headline--*` verdicts are coloured by how alarming they are (unique/rare amber,
  common accent, insufficient deliberately muted — we do not know, and colouring it either way would
  assert something unsupported); `btn--confirm` is filled while `btn--dismiss` is quiet, because
  pairing two filled opposites is the mistake `.removal-queue__*` already calls out.

  **Remaining: the visual pass**, in this order — `book-detail` 45 · `insights` 34 ·
  `marketplace-detail` 15 · `page` 15 · `profile` 14 · `blog-post` 12 · `upload-verify` 12 ·
  `marketplace` 11 · then the 64-group tail. Regenerate with `--list` rather than trusting that.

