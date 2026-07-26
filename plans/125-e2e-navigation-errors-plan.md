# Plan: E2E Test Suite — Navigation & Error Handling
**Issue**: #125
**Created**: 2026-07-25
**Status**: Approved
**Epic**: #125 + #126 on integration branch `feat/125-126-e2e` (epic state: `plans/125-126-e2e-epic-state.json`)

## Context
Issue #125 validates the full navigation and error-handling surface (7 user stories: home, top nav, swipe, footer, 404, RemoteData/network errors, unauthenticated redirect). All 7 stories are BUILT; the deliverable is the fully-tested state — plus reconciling the issue/story docs to the shipped surface, which has drifted since the 2026-07-08 baseline audit.

## Research Summary
Re-verification (2026-07-25, researcher-125) against current code found:
- **3 of 9 punch items already closed** by intervening work: RequireConfirmedEmail 403 integration (#124, `require_confirmed_email_test.exs:42-54`), most top-nav gaps (`MainNavTest.elm` unit-tests exposed `viewNav` incl. active class + Admin dropdown; `auth.spec.ts:82-131` drives Admin live), per-status login error messages (`LoginProgramTest.elm` asserts 422/403/423/503/401 rendered text).
- **Audit corrections A–H**: the "no global 401 handler" premise is FALSE (#173/#178 global session-expiry interceptor, `Main.elm:857-920`, unit+E2E tested); home CTAs changed by #235 (About `/about` + Marketplace `/marketplace`, old Antilibrary/Add-a-Book gone, `Main.elm:2986-2989`); brand dropdown = single About; Admin dropdown = Sources/Scrapers/Book Moderation (#267 removed in-app Metrics); `requiresAuth` public set grew 11→~18 (`Main.elm:441-502`); `PUT /api/settings/age_verification` removed (ADR-020).
- **Testability wall partially breached**: `Main` now exposes `viewNav` (pattern reusable). `viewHome` (:2979), `viewFooter` (:3037), `viewNotFound` (:3028), `requiresAuth` (:441), `initPage` (:505), `decodeSwipe` (:2519) remain unexposed/untested.
- **Feature-completeness**: 6/7 ✅; US-15.1.1 🟡 — feature built, story doc + issue text describe pre-#235 markup. Human decision (2026-07-25): reconcile docs to shipped nav.
- **No vacuous guards** in navigation/auth/login specs — keep it that way (#275).

## Approach Options
- **Option A (chosen): extract-by-exposing + targeted E2E.** Expose the six inline Main.elm functions (no behaviour change), unit-test them; close render/wiring gaps with Playwright. Mirrors the established `viewNav`/`MainNavTest` pattern. — Recommended, approved at kickoff.
- **Option B: E2E-only.** No Main.elm changes; everything via Playwright. — Rejected: slower suite, misses the requiresAuth matrix and decode branches, leaves the testability wall standing.
- **Option C: extract to modules.** Move view fns into `View/*` modules. — Rejected: larger diff for no additional coverage; exposing achieves the same testability.

## Human Decisions (kickoff, 2026-07-25)
- US-15.1.1 CTA drift → **update story doc + issue to shipped About/Marketplace CTAs** (#235 intentional).
- Standing rule: any live-drive discovery of unbuilt behaviour in a named story is **built in-scope** (escalate first only if it exceeds scope limits).

## Phases

### Phase 1: Re-baseline docs + live-drive feature-completeness
**Objective**: Reconcile issue/story docs to the shipped surface and drive all 7 stories live, filling the Pre-Check table with evidence.
**Agent(s)**: testing-coordinator (combined with #126 Phase 1 — one local stack boot)
**Steps**:
1. Live-drive each story on the local stack (rebuilt assets, `STACKS_E2E_TEST_HELPERS=1`): home render, nav auth/unauth sets, swipe (mobile emulation), footer, 404 (+tab title), a failed-submit error render, unauth `/library` → login-at-URL. Record evidence per story.
2. Specifically verify **form-input preservation on failed submit** (US-16.2.1 claim, never tested): if any form clears inputs on failure → feature gap, report for in-scope fix (contingency Phase 2b).
3. Update `docs/user_stories/US-15.1.1-home-page.md` CTAs to shipped About/Marketplace; update US-16.3.1 doc's obsolete "no global 401 handler" note to the shipped interceptor behaviour.
4. Fill Issue #125's Feature-Completeness Pre-Check table (hops + live-drive evidence + verdicts).
**Test Command**: n/a (docs + live-drive)
**Proving gate**: All 7 Pre-Check rows ✅ with a live-drive artifact each (observed render/redirect, not code-read).
**DoD Items**:
- [ ] Story docs reconciled; Pre-Check table ✅×7 with live evidence
- [ ] Form-preservation verdict recorded (works / gap→fix phase)

### Phase 2: Elm exposing + unit tests
**Objective**: Expose `viewHome`, `viewFooter`, `viewNotFound`, `requiresAuth`, `initPage`, `decodeSwipe`; add unit tests for each.
**Agent(s)**: elm-agent
**Steps**:
1. Widen `Main.elm` exposing (no behaviour change). Exposings must land in the same diff as consuming tests (elm-review narrows unconsumed exposings).
2. New `frontend/tests/`: home render (shipped markup), footer render (tagline), 404 render (heading/Go Home), `requiresAuth` full matrix (~18 public + protected), `decodeSwipe` valid→`SwipeReceived` / bad→`SwipeIgnored`, `initPage` guard (protected + no auth → Login page).
**Test Command**: `just run mix …` n/a — `cd frontend && npx elm-test`
**Proving gate**: Each new test fails when its assertion target is perturbed (spot-check one per file via temporary mutation) — coverage of built features has no red phase; specificity is the evidence.
**DoD Items**:
- [ ] 6 functions exposed + unit-tested — evidence: test file:line per function
- [ ] elm-test + elm-review clean

### Phase 3: E2E additions (contingent form-preservation fix folds in here if Phase 1 found a gap)
**Objective**: Close the render/wiring/behaviour gaps only Playwright can prove.
**Agent(s)**: testing-coordinator (elm-agent if a form-preservation fix is needed)
**Steps** (in `e2e/tests/navigation.spec.ts` unless noted):
1. Footer on ≥2 routes **and on the 404 page**; 404 page: heading, explanation, Go Home, nav visible, `page.title()` = "Not Found — The Stacks".
2. Home: `goto("/")` asserting shipped CTAs/hrefs.
3. Real swipe gesture (touch emulation) on a bookshelf → navigates; swipe on Search → no-op.
4. Marketplace dropdown sub-items (Create Listing, My Listings).
5. `auth.spec.ts`/`login.spec.ts`: form inputs retained after failed submit; URL bar unchanged when login renders at protected URL; redirect coverage beyond `/upload` (≥2 more protected routes).
6. No `if (count > 0)`-style guards; every wait-for-absence preceded by wait-for-presence.
**Test Command**: `cd e2e && npx playwright test --project=chromium` (local stack per `scripts/test-e2e.sh` conventions)
**Proving gate**: New specs pass against the live local stack; the swipe spec observed navigating a real page.
**DoD Items**:
- [ ] Punch items 1, 3, 4, 5, remainder of 2/6/8/9 closed — evidence: spec file:line each

### Phase 4: Regenerate audit → GREEN
**Objective**: Regenerate Issue #125's embedded audit tables/tally to the shipped state; 0 ❌ / 0 ⚠️.
**Agent(s)**: testing-coordinator
**Test Command**: full local suites (elm-test, mix test, chromium E2E) fresh
**Proving gate**: Audit tables reflect reality (spot-verified against runs, not report-read); DoD checkboxes carry evidence tokens.
**DoD Items**:
- [ ] Audit GREEN, tally regenerated, punch list empty

### Parallel Execution
**Independent phases**: Phases 2 and 3 are independent of each other after Phase 1.
**Merge order**: Phase 2 (Elm exposing) first — smallest, most foundational; then Phase 3; Phase 4 last.

## Open Questions
None — kickoff decisions recorded above.

## Integration Handoffs
- Phase 1 → 2/3: live-drive evidence + corrected markup targets (tests must assert shipped markup, not the old issue text).
- Phase 2 → 3: exposed function names/selectors stable for E2E reuse.
- Epic: merges into `feat/125-126-e2e`; `just run just ci` re-run green post-merge.
