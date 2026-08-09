# Issue #372: Four E2E failures that are neither flaky nor Wave 6 — nobody has looked at them

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
Found by the lead's Wave 6 live drive, 2026-08-01. After separating out the OOM noise (**#369**) and
the parallel-MFA artefact (**#371**), four specs still fail, **deterministically, at
`--workers=1`**, against a healthy preview:

| Spec | Assertion | Received |
|---|---|---|
| `public-profile.spec.ts:55` | `.profile__shelf` with text `Library`, count 1 | **0** |
| `public-profile.spec.ts:296` | same, anonymous viewer | **0** |
| `rss.spec.ts:189` | `GET /api/feeds/:user_id/:bookshelf_name` → 200 for a platform shelf | **404** |
| `privacy-placement.spec.ts:189` | first `.book--hidden` spine's aria-label contains the title just hidden | label was `1Q84`'s |

They are filed together because they were found together and share a shape — **shelf visibility and
what a shelf exposes** — not because they are known to be one bug. ⚠️ **Do not assume a single root
cause.** Investigate, then split if they diverge.

## What has already been ruled out
- **Not the OOM.** Zero 502s in the run that produced these (#369's 1 GB re-run).
- **Not concurrency.** They fail identically at `--workers=1`.
- **Not missing data.** The preview holds 175 books, 449 active placements, 226 bookshelves, 170
  users, and shelf visibility is populated: **198 owner / 15 public / 13 platform**.
- **Not a phantom selector.** `profile__shelf` is real markup — `Page/Profile.elm:149`.
- **Not Wave 6.** None of these files is in Wave 6's diff, and Wave 6 touched `Login.elm`,
  `Main.elm`, `Api.elm`, `Bookshelf.elm`, `Components/*`, `Settings/*` — not profile rendering, the
  feed endpoint, or spine visibility selection.

So: the class exists, the data exists, and the page still renders no shelves. That is a real
question and it is unanswered.

## A specific lead on the fourth
`privacy-placement.spec.ts:189` hides one book, returns to the shelf, and asserts on
`page.locator('[data-testid="book-spine"].book--hidden').first()`. Both halves of the aria-label
contract held — the hint `hidden (only visible to you)` was present and the class was applied — but
`.first()` resolved to **1Q84**, not the book the test had just hidden. ⚠️ That points at the spec
assuming its book is the *only* hidden spine, which is a different (and much smaller) defect than
the other three. Confirm before grouping it with them.

## User Stories
US-6.1 (feeds), US-10.5.x (public profiles), placement visibility.

## Scope Check
⚠️ **Investigation first, then scope.** If these are one bug, one issue. If they are three or four,
split — and this ticket becomes the parent. Do not force them into one fix.

## Technical Requirements
1. **Establish, for each, whether the product or the spec is wrong.** Drive the surface live and
   compare against what the spec asserts. A spec asserting a contract the product never promised is
   a spec defect; state which it is per row before fixing anything.
2. **Answer the profile question first** — two of the four are the same assertion, so it is the
   highest-leverage. A discoverable reader's profile renders zero `.profile__shelf` elements while
   the database holds 15 public and 13 platform bookshelves. Either the profile query excludes them,
   the fixture's reader owns none, or the page renders them under different markup.
3. **Check whether the RSS 404 shares the profile cause.** Both concern "which shelves are exposed
   to a non-owner". If the feed endpoint and the profile page disagree with each other about that,
   that disagreement is the bug and is worth more than either symptom.
4. **Fix `privacy-placement.spec.ts:189`'s selector regardless.** Asserting on `.first()` of a class
   that can legitimately match several elements is unsound even once the other three are resolved.
5. **No guard-shaped fixes.** ⚠️ `if (count > 0)` around any of these assertions makes the spec
   unable to fail — the project already carries 16 such guards (audit **#275**). Do not add a
   seventeenth to turn this ticket green.

## Reviewer Context
- ⚠️ **Run against a 1 GB machine** (`fly scale memory 1024`) or #369's OOM will bury the signal in
  unrelated 502s. The lead's clean baseline: 282 passed / 9 failed / 12 skipped, zero 502s.
- ⚠️ `--workers=1` when reproducing, so #371's MFA artefact does not add three more red rows.
- The preview branch read for the data above is `br-falling-wave-and3e0fr` (project
  `royal-boat-46711655`).
- Related: **#369** (OOM), **#371** (parallel MFA), **#370** (the other real bug this run surfaced),
  **#275** (the vacuous-guard audit).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| E2E | yes | ❌ all four pass at `--workers=1` against a 1 GB preview |
| Live drive | yes | ❌ each surface driven and the product-vs-spec verdict recorded per row |
| Regression | yes | ❌ whichever product defects are found get a test at their own layer, not just E2E |
| Others | no | n/a |

## Definition of Done
- [x] Per-row verdict — evidence: ALL FOUR are SPEC defects, zero product defects (verdicts below); repaired by `630961cf` (2026-08-03, "repair three E2E locators that described DOM and contracts the product no longer has")
- [x] Profile shelf question answered — evidence: the rows were rendering correctly the whole time. `.profile__shelf` gained a sibling "Feed" anchor when the Atom subscribe link shipped, so the row's `textContent` became `"LibraryFeed"` — and the spec's anchored `hasText: /^Library$/` matched NOTHING. Cause: a locator describing pre-feed DOM, not a query/exposure defect. Fix: `shelfRow()` filters on the row's own exact browse link (both :55→:76 and :296→:320 rows)
- [x] Whether RSS shares that cause — evidence: NO. The profile rows were correct DOM mis-read by a locator; the RSS 404 was correct AUTH POLICY mis-modelled by the spec — a `platform` shelf is signed-in-only on the Audience ladder (`Stacks.Feeds.feed_requires_auth?/1`, owner decision 2026-07-29), and the `request` fixture carries no Authorization header, so the read was anonymous and 404'd BY DESIGN. The repair reads the feed as the signed-in reader, and the anonymous-404 contract got its own test (`rss.spec.ts:247`). Neither row was an over-exposure — the feared urgent case is ruled out; the product was stricter than the spec assumed
- [x] `privacy-placement.spec.ts:189` selector made sound — evidence: `630961cf` — fresh isolated user (`landAsFreshUser`) owning exactly ONE placement + `toHaveCount(1)` on `.book--hidden` (an assertion, not a guard) + attribute-contains checks; the `.first()`-of-many read is gone. Also corrected the identity token: the spine's raw `book.title`, not the overlay's `displayTitle` (which reads "Not yet identified" on `barcode_unverified` editions — the #370 surface)
- [x] All four pass, no assertion weakened or guarded — evidence: 2026-08-09 full real-login run (301 passed): `public-profile.spec.ts:76` ✓ `:320` ✓ `rss.spec.ts:207` ✓ `privacy-placement.spec.ts:189` ✓ — at the shipped parallel worker count, stronger than the filing's `--workers=1` bar; the repair diff deletes no assertion and adds none of the #275 guard shapes
- [x] `staff-review` verdict recorded below — see close-out

## Dependencies
Surfaced by the Wave 6 live drive. Independent of Wave 6. Reading the results requires **#369**'s
sizing fix or a manually resized machine. Needs an owner wave assignment — these are pre-existing
and not launch-blocking on current evidence, but two of them concern **what a stranger can see of a
reader's shelves**, so if the profile cause turns out to be an over-exposure rather than an
under-exposure, this becomes urgent.

## Agent Assignment
elixir-agent + elm-agent; qa for the selector.

## Progress Notes
Filed 2026-08-01 by the lead. The rule-outs are each backed by a run or a query: the 1 GB run for
the OOM, the `--workers=1` run for concurrency, the preview-branch counts for data, `grep` for the
selector, and `git diff main...HEAD` plus the Wave 6 file-ownership map for attribution. No fix
attempted — the point of this ticket is that four deterministic failures were sitting inside a run
everyone had learned to read as flaky.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09, of `630961cf` + today's run): **LGTM** — each repaired locator carries the why in-comment (the "LibraryFeed" textContent trap, the Audience-ladder auth semantics, the count-1 soundness argument), the anonymous-404 behaviour was promoted to its own test instead of being silently accommodated, and the fix direction was tighten-not-weaken throughout. The filing's discipline (four rule-outs, "do not assume one root cause") is what made this close-out cheap: the four rows split exactly as it suspected — three UI-contract drifts and one unsound selector.
