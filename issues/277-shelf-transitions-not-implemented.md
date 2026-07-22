# Issue #277: US-1.2.5 Bookshelf Transitions Are Not Implemented (No Visible Transition)

## Summary
The #270 live drive proved that **no bookshelf navigation transition renders at all**. Every
shelf→shelf navigation applies the same class, `fade-through-dark-in`, and that class is an **empty
CSS rule** (`frontend/css/main.css:1802`) — computed `animation-name: none`, `animation-duration: 0s`.
All four of US-1.2.5's acceptance criteria fail against the running app.

## User Stories
- US-1.2.5 — Bookshelf Navigation Transitions (`docs/user_stories/US-1.2.5-shelf-transitions.md`)

## Epic membership — child of #112, delivered on `feat/e2e-112`
**This is an epic child of #112 and gates its PR.** #112 names US-1.2.5 as a covered story; rather
than de-scope the story, the decision (2026-07-21) is to **build it in its entirety** on the epic's
integration branch, so #112 delivers what it claims. Branch from `feat/e2e-112`, merge back into it.

Two #112 punch items move here, because they test this feature and cannot be written before it exists:
- **punch #9** — unit test for `transitionClass`: adjacent pair → slide class, room pair → fade class
- **punch #21** — E2E: transition classes applied, with computed `animation-name`/`duration` asserted

⛔ **Do not write those tests against the current behaviour** — it is a silent no-op, and a test
asserting "the class is applied" passes today while the feature does nothing. That trap is exactly
what #270 caught. Assert **computed style**, not class presence alone.

## Phase 0 — design pass (REQUIRED FIRST, before any implementation)
Per the orchestrator's rule that non-trivial features get a design pass ahead of implementation.
Produce a short design note (`docs/decisions/` if the call is architectural, otherwise in this issue)
resolving these **before** writing code — each is a real fork, not a detail:

1. **Slide direction.** Is the horizontal slide directional (Library→WishList slides opposite to
   WishList→Library, implying an ordering of the shelves) or always the same direction? The story's
   route-pair table (`US-1.2.5-shelf-transitions.md:129-136`) names *which* pairs slide, not which way.
2. **Class-clearing mechanism (Defect 3).** The class is never reset, so an animation would fire at
   most once. Options: an `animationend` subscription, a `Task`-driven reset, or keying the element so
   it remounts. This is an Elm-architecture decision with testability consequences — pick and justify.
   Note the constraint that a re-render with an *identical* class string does not restart a CSS
   animation.
3. **Defect 4 — the `BookDetail` slide branches.** Delete as dead code, or repurpose for the overlay's
   own animation? Book clicks open an overlay, never push a route (ADR-005), so they are currently
   unreachable.
4. **`themeClass` reconciliation.** The story document says the transition is driven by `themeClass`;
   the implementation drives it from `transitionClass`. They disagree. Decide which is authoritative
   and **amend the story document** — do not leave the spec contradicting the code.
5. **Reduced motion.** Confirm the suppression approach against the existing pattern (below).

## Goal
Navigating between bookshelves produces the transitions the story specifies: a horizontal slide
between adjacent bookshelves, a fade-through-darkness into/out of room pages, 300–500 ms, with the
navigation bar visually stable throughout — and honouring `prefers-reduced-motion`.

## Scope Check
- More than 3 controllers? No — frontend only (`Main.elm` + `main.css`).
- More than 2 new endpoints? No — none.
- More than ~300 lines of production code? No — one function plus a CSS block.
- Combines unrelated concerns? No — one story's animation layer.

## Wiring
Router wiring: includes wiring — user-facing on completion. The route plumbing already exists
(`Main.elm:1209` → `Main.elm:2440-2447`); this issue makes it produce a visible effect.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.2.5 — Bookshelf Transitions | `Main.elm:1208-1209` (compute) ✅ · `Animation/Transition.elm:27-42` `transitionClass` ✅ · `Main.elm:2440-2448` (class + `animationend` on `main.app__main`) ✅ · `main.css:1782-1842` CSS ✅ | Live drive 2026-07-21 (captures transient/gitignored): adjacent forwards → `slide-in-right` / `0.3s`; adjacent backwards → `slide-in-left` / `0.3s`; room → `fade-through-dark-in` / `0.4s`. Mid-animation screenshots show the slide offset and the dark fade. | ✅ | Built and observed live |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### Defect 1 — no adjacent-shelf slide; every route pair yields the same class
> ⚠️ **Location corrected 2026-07-21:** #271 has since **extracted** this function out of `Main.elm`.
> It now lives at **`frontend/src/Animation/Transition.elm:16-17`**, imported at `Main.elm:20` and
> called at `Main.elm:1208`. The `Main.elm:2355-2365` references below and elsewhere in this issue are
> stale — edit `Animation/Transition.elm`. (#271 is merged, so this is already true on the branch.)

`transitionClass : Route -> Route -> String` (now `frontend/src/Animation/Transition.elm:16-17`)
branches **only** on `BookDetail`. Every bookshelf→bookshelf pair falls through to the `_ ->`
catch-all and returns `RoomTransition.fadeThroughDarkIn`.

Observed live 2026-07-21 (captures transient, not retained in-repo):

- `/library` → `/antilibrary` (adjacent — story wants a **horizontal slide**):
  `"mainClass": "app__main fade-through-dark-in"`
- `/antilibrary` → `/reading-pile` (room change — story wants **fade through darkness**):
  `"mainClass": "app__main fade-through-dark-in"`

The two cases are indistinguishable. The story's route-pair table
(`US-1.2.5-shelf-transitions.md:129-136`) requires a slide for Library/AntiLibrary/WishList pairs and
a fade only for Reading Pile / Looking for Home.

### Defect 2 — the applied class has no styling
`frontend/css/main.css:1798-1803`:

```css
/* ===== Room Transitions (fade through dark) ===== */
/* Placeholder: room transition classes applied via Elm but not yet styled.
   Safe to add opacity/overlay animations now that preserve-3d is removed. */

.fade-through-dark-in {}
.fade-through-dark-out {}
```

The comment states the intent explicitly. Measured on the live page: `animation-name: none`,
`animation-duration: 0s`, `opacity: 1`, `transform: none` — before, during, and after navigation.
`slide-in-right` / `slide-out-right` **are** styled (`main.css:1786-1796`, 0.3 s) but are never
applied to a shelf transition.

### Defect 3 — the transition class is never cleared (latent, blocks Defects 1–2 from working)
`model.transition` is set on `UrlChanged` (`Main.elm:1236`) and never reset to `Nothing`. The live
drive sampled the class 600 ms after navigation and it was still present:

```
AFTER : {"mainClass":"app__main fade-through-dark-in", ...}
```

Because the class string is identical on every subsequent shelf navigation, re-rendering does not
remove and re-add it — so even once Defect 2 is fixed, a CSS animation would fire at most once per
class value and never re-trigger on later navigations. Any fix must clear the class (e.g. an
animation-end message, or a `Process.sleep`-free `Task`-driven reset) or otherwise force a restart.

### Defect 4 — the `SlideTransition` branches are unreachable from the UI
The `( _, BookDetail _ )` / `( BookDetail _, _ )` branches return the slide classes, but book clicks
open an **overlay** rather than pushing a route (ADR `docs/decisions/005-book-detail-overlay-not-route.md`,
`Main.elm:1378-1385`). Driven live 2026-07-21: clicking a spine left the
URL at `http://localhost:4000/library`, rendered `class="book-overlay"`, and `mainClass` stayed
`"app__main"` with **no** transition class. Decide whether these branches are dead code to delete or
should be repurposed for the overlay's own animation.

### Note on the `themeClass` mechanism
`US-1.2.5-shelf-transitions.md:131-133,147` describes the transition as driven by `themeClass`
(`shelf-library` → `shelf-antilibrary`). That class **does** change (`Page/Bookshelf.elm:65,78,91`,
applied at `Bookshelf.elm:283`), but the rules only set CSS custom properties (`--shelf-bg`,
`--shelf-text`, …) — `main.css:42-108` declares no `transition` or `animation` on them, and custom
properties do not animate by default. The story document and the implementation disagree about the
mechanism; reconcile them as part of this issue.

### Acceptance criteria to satisfy (from the story, `US-1.2.5-shelf-transitions.md:19-23`)
- Horizontal slide for adjacent bookshelf navigation.
- Fade-through-darkness for room transitions (Reading Pile, Looking for Home).
- Navigation bar remains visually stable during transitions.
- Transition duration 300–500 ms.

## Reviewer Context
- `Animation.SlideTransition.slideInRight` / `slideOutRight` / `RoomTransition.fadeThroughDarkIn` are
  **String constants** (`Animation/SlideTransition.elm:8,13`, `Animation/RoomTransition.elm:5`), not
  type constructors. `issues/112-e2e-shelf-browsing.md:428` describes them incorrectly.
- The live shelf DOM is the `shelf-row` family (`Page/Bookshelf/Helpers.elm:104-113`).
  `bookcase__shelf` does not exist anywhere in `frontend/`.
- `.app-header` is `position: relative` by design (`main.css:172-173`) — **not** `position: fixed`.
  The drive measured it stable across a transition (`top: 0, height: 71` before and after), so
  "nav remains fixed" should be read as "does not shift", and asserted as geometric stability rather
  than `getComputedStyle(nav).position === "fixed"`.
- `transitionClass` is now unit-testable: #271 is **merged**, and it lives at
  `frontend/src/Animation/Transition.elm:16` with an existing spec at
  `frontend/tests/Animation/TransitionTest.elm` (5 tests covering all three current branches). Extend
  that spec — do not create a parallel one.
- **The slide CSS already exists and is already in-band.** `main.css:1786-1796` defines
  `.slide-in-right` / `.slide-out-left` / `.slide-out-right` at `0.3s` — i.e. 300 ms, the bottom of the
  story's 300–500 ms band. Only the **fade** needs authoring from scratch; do not rewrite working
  slide CSS to satisfy the duration criterion.
- **A `prefers-reduced-motion` pattern already exists** in this stylesheet — `main.css:640` and
  `main.css:3196`. Follow it rather than inventing a third approach.
- `.app-header` is `position: relative` **by design**; assert geometric stability
  (`getBoundingClientRect()` unchanged), never `position === "fixed"` — that assertion fails against a
  working page.

## Test Audit
Compact format — a frontend animation issue with no API, DB, event, job, storage, cache, dbt, metric
or cost surface.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine (L10) | yes | ✅ — `frontend/tests/Animation/TransitionTest.elm` pins class selection (directional slide for adjacent pairs, fade for room pairs) and `clearOnAnimationEnd` (own-animation clear, bubbled-descendant ignore, repeat re-trigger). |
| E2E (browser) | yes | ✅ — `e2e/tests/shelf-transitions.spec.ts`, 9 tests, all asserting **computed** `animation-name`/`animation-duration`, never class presence alone. Failure power proven by mutation (below). |
| Performance & usability (L12) | yes | ✅ — computed `animation-duration` asserted within 300–500 ms for both transition types (slide 0.3 s, fade 0.4 s). |
| 1–9, 11, 13 | no | n/a — client-side CSS only; no server, data, or cost surface is touched. |

Verdict: ✅ GREEN — 0 ❌, 0 ⚠️.

**Mutation check (2026-07-21).** To prove the suite cannot repeat #277's original failure — an
assertion that passes against a dead feature — `main.css` was temporarily reverted to the defective
form (`.fade-through-dark-in {}` and `.slide-in-left {}` emptied) and the assets rebuilt.
**5 of 9 tests failed**, including the fade test and the repeat-re-trigger test. CSS restored and
rebuilt; `git diff frontend/css/main.css` is clean.

Known limit, recorded rather than papered over: the two `prefers-reduced-motion` tests still pass
under that mutation, because "suppressed" and "never existed" are both `animation-name: none` and are
indistinguishable in isolation. They are meaningful only as a pair with the positive tests that prove
the animation exists under normal motion. Their own guard is the `matchMedia` assertion described
below.

## Definition of Done
Live drive run 2026-07-21 against local Phoenix on `:4000` (`STACKS_E2E_TEST_HELPERS=1`,
`AGE_GATING_ENABLED=true`), assets rebuilt from `apps/core/assets` first. Artifacts in
the live drive of 2026-07-21 (values transcribed above; raw captures gitignored).

- [x] Adjacent bookshelf navigation applies a horizontal-slide class — evidence (live drive 2026-07-21, raw captures transient/not retained): forwards `{className: "app__main slide-in-right", animationName: "slide-in-right", animationDuration: "0.3s"}`; backwards → `slide-in-left` / `0.3s`; screenshot caught the content mid-slide, horizontally offset. Also gated in `e2e/tests/shelf-transitions.spec.ts` (asserts computed style, run on preview)
- [x] Room navigation (Reading Pile / Looking for Home) applies a fade-through-darkness class with non-zero styling — evidence (live drive 2026-07-21): `{className: "app__main fade-through-dark-in", animationName: "fade-through-dark-in", animationDuration: "0.4s"}`; screenshot caught the page mid-fade, dimmed to near-black with the header still lit
- [x] Computed `animation-duration` is within 300–500 ms for both transition types — evidence: slide `0.3s`, fade `0.4s`, both asserted in-band by `shelf-transitions.spec.ts`
- [x] The transition class is cleared after the animation so repeat navigations re-trigger it — evidence: **preview** `--repeat-each=3` against `https://stacks-core-pr-feat-e2e-112.fly.dev` → 27/27 green, EXIT 0 (log: `scratchpad/preview-repeat3.log`); failure power proven by runtime mutation (`addStyleTag` forcing `animation: none !important` → no `animationend` fires → class never cleared → `TimeoutError`, EXIT 1). Local capture (live drive 2026-07-21, transient) showed the sequence `[null, slide-in-right, null, slide-in-left, null, slide-in-right, null, slide-in-left, null]`.
  > ⚠️ **This item was AMBER until 2026-07-21 and local green is what hid it.** The original test chained `click → waitForTransitionCleared → click`. Because Elm applies the class on the *next animation frame*, "no transition class present" was **already true** when that wait ran, so it returned instantly having observed nothing and navigations piled into one frame — the class was swapped mid-flight rather than removed-and-re-added. It passed 27/27 locally and was non-deterministic against the deployed preview. Worse, an instrumented run **passed the old assertions while never exercising the mechanism**: the second `slide-in-right` was reached by direct swap from `slide-in-left` with no cleared state between, so the assertion was satisfied by an unrelated clear. Fixed by pinning the *applied* half of the invariant (`recordedTransitions(page, n)` before each wait) plus a new `toHaveLength(3)` requiring all three navigations to animate. Element identity was ruled out as a cause: a marker expando survived every navigation and three independent observers (captured-node, ancestor-subtree, rAF poll) produced identical sequences — Elm patches the class, it never remounts `main.app__main`.
- [x] `.app-header` geometry is unchanged across both transitions — evidence (live drive 2026-07-21): `{top: 0, left: 0, width: 1280, height: 71.390625}` byte-identical across before / during-adjacent / after-adjacent / during-room / after-room
- [x] `prefers-reduced-motion: reduce` suppresses the animation — evidence (live drive 2026-07-21): `{emulationActive: true}` with `slide-in-right` → `animationName: "none"` and `fade-through-dark-in` → `animationName: "none"`; also gated in `shelf-transitions.spec.ts` (asserts `matchMedia` active before asserting suppression)
- [x] Defect 4 resolved — the `BookDetail` slide branches are deleted; rationale recorded in the `Animation/Transition.elm` module docstring (lines 13-15) and story doc line 170 — evidence: no `BookDetail` reference remains in `Animation/Transition.elm`
- [x] The story document's `themeClass` mechanism is reconciled with the implementation — evidence: `docs/user_stories/US-1.2.5-shelf-transitions.md:132-135` records that `themeClass` was never implementable as a transition driver and that `transitionClass` is authoritative; `:186` documents `themeClass`'s real job (palette only)
- [x] **Feature-Completeness Pre-Check (above) is ✅** — happy path built end-to-end and observed on a live stack — evidence: live drive 2026-07-21 against local Phoenix `:4000` (assets rebuilt from `apps/core/assets`), values transcribed on the rows above; **and re-run green on the deployed preview** (`shelf-transitions.spec.ts` 27/27 under `--repeat-each=3`); full chromium suite **206 passed, 10 skipped (all environment-gated, itemised), 0 failed**
- [x] Every behaviour has a validation path — unit (`TransitionTest.elm`: class selection + `clearOnAnimationEnd`) + E2E (computed animation, 9 tests) + reduced-motion
- [x] Tests written and passing — `elm-test` green; `shelf-transitions.spec.ts` 9/9, stable across `--repeat-each=3` (27/27)
- [x] Standards compliance verified — evidence: `just run just verify` → EXIT 0 on `feat/e2e-112` (`mix test` 2749 tests / 0 failures; `elm-test` 900 / 0; dbt PASS=64/64 models, PASS=231/231 tests; `mix proto.sync --check` clean; coverage 81.9%)
- [x] **Test audit (embedded above) is GREEN** — 0 ❌, 0 ⚠️ — evidence: L10 unit `frontend/tests/Animation/TransitionTest.elm` (23 tests: class selection for all six adjacent pairs + all room pairs, plus `clearOnAnimationEnd` incl. the bubbling filter); L12/E2E `e2e/tests/shelf-transitions.spec.ts` (9 tests, all asserting **computed** `animation-name`/`animation-duration`, never class presence), stable 27/27 under `--repeat-each=3`. Non-vacuity: unit layer shown failing 9/9 against pre-fix `transitionClass`; CSS layer shown failing against the pre-fix empty rule (`animation-name=none, duration=0s`)
- [ ] **`completion-audit` skill passed on the integrated branch** — not run by this drive; remains open
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — every item with an evidence token

## Dependencies
- **#271 — SATISFIED (merged 2026-07-21).** `transitionClass` is extracted to
  `Animation/Transition.elm` and unit-testable; `TransitionTest.elm` exists to extend.
- Discovered by #270 (live-drive gate); values transcribed in this issue and #270 (raw captures gitignored).
- **Epic child of #112 — gates its PR.** Branch from `feat/e2e-112`, merge back into it. #112's
  US-1.2.5 pre-check row goes ✅ only when this issue's live drive passes.

## Agent Assignment
`elm-agent` (implementation), `testing-coordinator` (E2E + reduced-motion validation)

## Progress Notes

### 2026-07-21 — deferred live drive completed; two test defects fixed, implementation untouched

`shelf-transitions.spec.ts` was authored but never run against a stack. Its first real run was red.
Establishing a clean baseline first (assets rebuilt from `apps/core/assets`, four untracked scratch
specs — `fc112-drive`, `fc112-drive2`, `fc270-drive`, `fc270-drive2` — removed) reduced the reported
**4 shelf-transition + 1 marketplace** failures to **3 shelf-transition failures and no marketplace
failure**. Both remaining causes were in the test, not the feature. **No production code changed** —
`git diff` touches only `e2e/tests/shelf-transitions.spec.ts` and this issue.

**(a) `the slide is directional` — racy timing.** Elm's `pushUrl` updates `location` synchronously
inside `update`, but the class is applied on the next animation frame. `expect(page).toHaveURL(...)`
resolves in that gap, so reading the MutationObserver log immediately found the navigation not yet
rendered. Deterministic, not intermittent — 6/6 failures under `--repeat-each=6` — which is why it
read as a real defect. Instrumented proof: reading immediately gave
`[{className: "app__main", animationName: "none"}]`; 100 ms later the same log held
`slide-in-left` / `0.3s`. Fixed with a `recordedTransitions()` helper that waits for the sample to be
observed. Tests 1, 2 and 4 passed only by luck and carried the same latent race; all now use the
wait. This is a wait, not a softened assertion — if the class stops being applied the wait times out
and the test fails.

**(b) reduced-motion — the emulation was silently dropped.** `test.use({ reducedMotion: "reduce" })`
never reaches `contextOptions` in this setup (Playwright 1.58.2): probed
`contextOptions.reducedMotion === undefined` and the page matching
`(prefers-reduced-motion: no-preference)`. So the CSS at `main.css:1834-1842` was never exercised and
the tests failed against a stylesheet that is in fact correct. `browser.newContext({reducedMotion})`
and `page.emulateMedia({reducedMotion})` both work; the spec now uses `emulateMedia` **and asserts
`matchMedia(...).matches` before asserting suppression**, so the emulation can never silently no-op
again. That guard matters more than the fix: without it this failure mode is invisible, which is the
same shape as the empty `.fade-through-dark-in {}` rule that started this issue.

**(c) marketplace — environmental, not caused by #277.** Could not be reproduced on a clean baseline:
`marketplace.spec.ts` + `marketplace-draft.spec.ts` pass 11/11, and marketplace passes again in the
full suite. Consistent with the reporting agent's note that its bundle was stale mid-flight. #277
touches only `Animation/Transition.elm`, `main.css` and `Main.elm`'s transition wiring — no
marketplace surface.

**Results.** Full chromium suite **206 passed, 10 skipped, 0 failed**. All 10 skips are the
known-legitimate set: 6 × `dashboards.spec.ts` and 1 × `transparency.spec.ts` live-panel (need
deployed Grafana/VictoriaMetrics), 1 × `confirm-email.spec.ts` full flow and 2 × `password-reset.spec.ts`
(need a mail adapter). Zero unexplained skips; `shelf-transitions.spec.ts` skips nothing.
`shelf-transitions.spec.ts` is stable at 27/27 across `--repeat-each=3`.

### Filed
Filed 2026-07-21 by the #270 live-drive gate. Evidence (values transcribed above; raw captures gitignored) —
the #270 live-drive captures (values transcribed above; raw files transient/gitignored) and the matching
`125-a`…`125-g` screenshots. Console and page errors were **empty** across all drives, so this is a
silent no-op, not a runtime failure.
