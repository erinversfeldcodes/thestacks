# Issue #275: Audit and Remove Vacuous `if (count > 0)` Guards Across the E2E Suite

## Summary
A full sweep of `e2e/tests/` found **16 assertions wrapped in `if ((await …count()) > 0)` guards**.
A guard of this shape means the test **passes when the element is absent** — so it can never fail, and
a regression that removes the element entirely is reported as green. Seven of the sixteen are in
Issue #112's scope and are handled there (punch #18/#19). **The other nine have no owner** and are
tracked here.

This is not a hypothetical risk. In #112's scope the pattern was proven to hide two distinct defects:
- Four empty-state assertions (`bookshelf.spec.ts:77,90,101,127`) have asserted **nothing since March
  2026**, because every seeded suite user has placements on those shelves.
- `reading-pile.spec.ts:19` guards an armchair assertion whose selector is **`.reading-pile__armchair`**,
  while the live DOM emits `class "armchair"` (`frontend/src/Page/Bookshelf/ReadingPile.elm:137`).
  The guard masks a **wrong selector** — unguarded, the test fails.

The second case is the dangerous one: a vacuous guard does not merely skip a check, it can conceal a
test that was never correct.

## User Stories
None directly — this is test-suite integrity work. It protects the assertions backing US-1.2.x
(#112), US-2.x (book detail, #114), and the catalogue/upload/editions surfaces.

## Goal
Every assertion in `e2e/tests/` either runs unconditionally, or its conditionality is **justified in a
comment** stating why the element is legitimately optional. No assertion silently passes because its
target is missing.

## Scope Check
- Does this issue touch more than 3 controllers? No — no production code expected (unless a guard
  reveals a real defect, which is then filed separately).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No — test edits, plus possible seed fixtures.
- Does this issue combine unrelated concerns? It spans several spec files, but it is **one** defect
  class with one remedy. Splitting per-file would fragment a single audit.

## Wiring
Router wiring: implementation-only (test-suite integrity). No user-facing surface.

## Feature-Completeness Pre-Check
n/a — no user stories; this issue builds no user-facing behaviour. Per the "do not trust the
self-classification" rule: where removing a guard reveals that the underlying **feature** is missing
(rather than the test being wrong), that is a blocking finding to file as its own issue — see the
fork rule in Technical Requirements.

## Technical Requirements

### Inventory (verified 2026-07-21)
Out-of-scope-for-#112 guards, to be resolved here:

| File | Lines | Note |
|------|-------|------|
| `e2e/tests/book-detail.spec.ts` | 44, 74, 85 | Overlaps #114's charter — coordinate, do not duplicate |
| `e2e/tests/catalogue.spec.ts` | 66, 100, 105 | `:100`/`:105` guard pagination — may be legitimately conditional on result count |
| `e2e/tests/upload.spec.ts` | 330, 336 | Guards error/identified branches — likely a genuine either/or, verify |
| `e2e/tests/editions.spec.ts` | 30 | `cardLink` presence |

Handled in #112, listed for completeness (**do not touch here** — scope-lock):
`bookshelf.spec.ts:77,90,101,127`; `reading-pile.spec.ts:19,29,40`.

Also review `shelf-actions.spec.ts:74` — it uses `test.skip((await addButton.count()) === 0, …)`,
which is a *declared* skip rather than a silent pass. That is materially better, but a skip is still
not a pass; decide whether the precondition can be made deterministic.

### The fork — apply per guard
For each guard, determine which case applies and act accordingly:
1. **Data is deterministic; guard is vestigial** → delete the guard, assert unconditionally.
2. **Data is non-deterministic** → make it deterministic (seed fixture / setup call), then delete the
   guard. Prefer additive seed data over a reset endpoint, per the approach taken in #272.
3. **Element is legitimately optional** (a genuine either/or branch, e.g. `upload.spec.ts:330/336`) →
   keep the conditional, but restructure so **something is always asserted** on both branches, and add
   a comment stating why it is conditional.
4. **Guard masks a wrong selector or a missing feature** → the test is broken, not shy. Fix the
   selector; if the *feature* is absent, file a separate issue and reference it here. **Do not** delete
   the assertion to make the suite green.

### Non-negotiable
- A test that cannot fail is worse than no test: it occupies the space where coverage should be and
  reports green. Removing a guard without making the assertion meaningful does not resolve that item.
- Prove non-vacuity: for each de-guarded assertion, demonstrate it **fails** when the target is
  removed or the feature is broken.

## Reviewer Context
- The #112 investigation established that these guards are largely **vestigial**: in that suite they
  were added in `6e5d6d7a3` (14:23) and the per-suite seeded users that made them unnecessary landed in
  `c41ab528` (15:36) — 73 minutes later. Expect similar provenance elsewhere; check `git log` before
  assuming a guard was deliberate.
- Project standard: `docs/agents/standards/testing.md` — "a structure-only gate is never completion
  proof". A guard that passes on absence is precisely that failure mode.
- Project rule: never dismiss a flaky or non-asserting test as "not ours" — find and fix it.
- `e2e/tests/helpers.ts` provides additive setup (`ensureBookOnShelf`, `ensureBookOnLibrary`). There is
  **no** subtractive/reset helper and none should be added casually — see #272's rationale.

## Test Audit
Compact format — test-integrity issue.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| E2E (browser) | yes | ❌ → ✅ — all 9 out-of-#112 guards resolved via the fork above; each de-guarded assertion proven to fail when its target is removed |
| Meta / suite integrity | yes | ❌ → ✅ — a documented convention (and ideally a lint or grep check in CI) preventing reintroduction |
| 1–13 (app layers) | no | n/a — no application surface changed; this issue alters test code only. Any product defect uncovered is filed as its own issue. |

## Definition of Done
- [x] All 9 out-of-#112 guards triaged against the four-way fork, with the chosen case recorded per guard — evidence: triage table (completion report 2026-07-23; provenance traced to 6e5d6d7a3/8ad7ec6f8/0fd25a972), plus the settings 502 trio and seed-skip migrations folded in
- [x] Vestigial guards deleted; assertions run unconditionally — evidence: commit 14b5fd2c; check script greps clean
- [x] Legitimately-conditional branches restructured so something is always asserted — evidence: upload.spec either/or branches assert terminal state on both paths with allow-markers (commit 14b5fd2c)
- [x] Each de-guarded assertion proven non-vacuous — evidence: per-guard broken-selector failure excerpts in the triage table (every de-guarded assertion demonstrated to fail when its target is removed)
- [x] Any masked defect (wrong selector / missing feature) filed as a tracked issue — evidence: none found (editions:30 case-4 candidate investigated and cleared); NOTE the removed settings 502 guards immediately exposed a REAL preview OOM, fixed via the preview VM memory bump (7bedbbf5) — the class working as intended
- [x] Reintroduction prevented — evidence: scripts/check-e2e-vacuous-guards.sh (proven exit-1 on each idiom) wired into lint-elm.sh (just ci) + test-e2e.sh pre-flight, plus the convention section in docs/agents/standards/testing.md
- [x] Full E2E suite green — evidence: local 220/10-env-skips/0-failed (2026-07-23), then deployed-preview record run 230 passed / 0 skipped / 0 failed after the #269 env work
- [x] `just verify` passes — evidence: just ci 2026-07-23 all groups PASS (dockle local caveat only)

## Dependencies
- Coordinate with **#114** (E2E Book Detail Overlay) on `book-detail.spec.ts` — that issue may
  rewrite those specs; align rather than collide.
- **Not** an #112 epic child: the shelf-browsing guards are handled inside #112, and blocking #112's PR
  on an audit of unrelated spec files would be scope creep. Tracked independently by design.

## Agent Assignment
`testing-coordinator`, with `playwright`/`elm-agent` support where a selector or feature defect is found.

## Progress Notes
[Updated by agents during execution.]
