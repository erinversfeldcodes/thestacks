# Issue #372: Four E2E failures that are neither flaky nor Wave 6 — nobody has looked at them

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
- [ ] Per-row verdict: product defect or spec defect, with reasoning — evidence: the four verdicts
- [ ] Profile shelf question answered — evidence: the cause, not just the fix
- [ ] Whether RSS shares that cause, stated either way — evidence: the comparison
- [ ] `privacy-placement.spec.ts:189` selector made sound — evidence: diff
- [ ] All four pass, no assertion weakened or guarded — evidence: the run + diff
- [ ] `staff-review` verdict recorded below

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
