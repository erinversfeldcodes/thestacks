# Issue #274: Navigating Away Mid-Load Must Not Corrupt Page State

## Summary
No test covers navigating away from a shelf **while its API request is still in flight**. The
in-flight `ShelvesLoaded` response can arrive after the user has already moved to another page; if the
old response is applied to the new page's model, the user sees the wrong shelf's books or a crash.
This is US-1.2.5's sad path, and it is untested at every layer.

Spun out of #112 punch item #10. It sits on the boundary with **#125 (E2E Navigation & Error
Handling)** — it is tracked separately here so the boundary is an explicit decision rather than an
accident of whichever issue got there first.

## User Stories
- US-1.2.5 — Shelf Transitions (sad path)

## Goal
Navigating away from a shelf mid-load is proven safe: the stale response is discarded, the destination
page shows its own state, no console error is raised.

## Scope Check
- Does this issue touch more than 3 controllers? No — no Elixir expected.
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No — a test; production change only if a
  defect is found.
- Does this issue combine unrelated concerns? No.

## Wiring
Router wiring: implementation-only (test coverage; plus a fix if the drive finds a real defect).

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.2.5 — Shelf Transitions (sad path: navigate away mid-load) | `Main.elm:1347-1396` (page-msg dispatch), `Main.elm:542-549` (Library/AntiLibrary/WishList all → one `PageBookshelf`), `Page/Bookshelf.elm:192-231` (init fires the GET), `:238-268` (`ShelvesLoaded` applied) | Stale sibling response **was** applied — the Antilibrary rendered the Library's book under the "Antilibrary" label | 🟡 → ✅ | **Real defect, fixed in-scope.** `ShelvesLoaded` now carries a `requestKey`; a response whose key ≠ the current config's key is discarded (`Page/Bookshelf.elm:173-181`, `:241-249`) |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

**Note:** this pre-check may legitimately land 🟡/❌ — that is the point of the issue. If the stale
response *is* mishandled, that is a **product defect** to fix in-scope (it is small and squarely
within this issue's charter), not something to de-scope.

## Technical Requirements
- Primary layer is an **Elm program test** in `frontend/tests/NavigationProgramTest.elm` (existing
  tests at `:51`, `:78`, `:108`, `:135` — none covers this): start on a shelf, leave the HTTP request
  unresolved, dispatch the route change, **then** resolve the original request, and assert the
  destination page's state is intact and the stale payload was not applied.
- Verify how `Main.elm` dispatches page messages: whether a `ShelvesLoaded` arriving for a page that
  is no longer current is discarded. If nothing discriminates by current page, that is the defect.
- Cross-check the same hazard for `ReadingPile` / `LookingForHome`, which own separate models
  (`BooksLoaded`/`books`) — the unified page's behaviour does not imply theirs.
- Consider whether a browser-level E2E adds value beyond the program test. It likely does **not** —
  timing a mid-flight navigation in Playwright is inherently flaky, and this project's standards
  reject flaky tests. Prefer the deterministic program test; record the reasoning rather than adding
  a timing-dependent spec.

## Reviewer Context
- Unified `Page.Bookshelf` uses `ShelvesLoaded` + `shelves : RemoteData Http.Error (List Shelf)`
  (`Page/Bookshelf.elm:140,160`). `ReadingPile` / `LookingForHome` use `BooksLoaded` + `books`
  (`ReadingPile.elm:41`, `LookingForHome.elm:35`). They are **not** interchangeable.
- Book click opens an **overlay**, not a route push (`Main.elm:1378-1385`, ADR-005) — an overlay open
  is not a page change and should not be conflated with one in these tests.
- Boundary with **#125**: #125 owns navigation and error handling broadly. This issue owns only the
  stale-response-after-route-change hazard on shelf pages. If the fix turns out to be a general
  message-routing change in `Main.elm`, hand it to #125 rather than growing this issue.

## Test Audit
Compact format.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine (L10) | yes | ✅ — `NavigationProgramTest.elm` "navigate away mid-load (Issue #274)": stale sibling `ShelvesLoaded` discarded (state + view), and the matching response still applied (non-vacuity guard) |
| Elm state machine — pile pages | yes | 🟡 — hazard **does not exist** for `ReadingPile` / `LookingForHome`: each is the sole route behind its own `Page` constructor, so `Main.elm:1398-1459`'s constructor match already drops any post-navigation response. Only the precondition (independent `Loading` state) is asserted; driving `BooksLoaded` directly is blocked on #271 exposing `Msg(..)`. See Progress Notes. |
| E2E (browser) | yes | n/a — deliberately excluded: mid-flight navigation timing is inherently flaky; the program test is deterministic and proves the same invariant. Rationale recorded per the "n/a is a stated finding" rule. |
| 1–9, 11–13 | no | n/a — client-side state handling only; no API, DB, event, job, storage, cache, dbt, metric or cost surface |

## Definition of Done
- [ ] Program test: navigate away mid-load, stale response resolved afterwards, destination state intact — evidence: test name + run output
- [ ] Same hazard covered for `ReadingPile` / `LookingForHome` — evidence: test name(s)
- [ ] Test **fails** if the stale response is applied — evidence: deliberately broken run showing the failure
- [ ] If a real defect was found, it is fixed and the fix is covered — evidence: diff + test; or "no defect found" with the evidence that established it
- [ ] Every behaviour has a validation path — evidence: the program tests above; browser E2E `n/a` with the rationale recorded in the audit
- [ ] `elm-test` green — evidence: command → pass count
- [ ] `just verify` passes — evidence: command → output

## Dependencies
None. Related: #125 (E2E Navigation & Error Handling), #112 (parent epic).

## Agent Assignment
`elm-agent`. Reviewer: `elm-reviewer`.

## Progress Notes

### elm-agent — real defect found and fixed

**Verdict: this was a genuine product defect, not a false alarm.**

The hazard is narrower than the issue assumed, but real. `Main.elm` dispatches page messages by
matching on the `Page` constructor and falling through to `( model, Cmd.none )`
(`Main.elm:1347-1396`, `:1398-1436`, `:1438-1459`). That already discards a stale response for every
**cross-constructor** move — Library → Reading Pile was never broken.

The gap was **same-constructor siblings**. Library, Antilibrary and Wish List all render through the
one unified `Page.Bookshelf` module and all sit behind the single `PageBookshelf` constructor
(`Main.elm:542-549`, each via `initBookshelf` at `:514-526`). `BookshelfResponse` carries no
bookshelf identity (`Types/Shelf.elm:18-22`), so `Bookshelf.update` had no way to tell whose response
it was holding and applied it unconditionally. Result: leaving `/library` mid-load and landing on
`/antilibrary` painted the **Library's books onto the Antilibrary**, under the "Antilibrary" label.
The pre-fix test run captured exactly that view.

**Fix (page-local — no `Main.elm` change, so the #125 boundary is respected):** `ShelvesLoaded` now
carries a request key identifying the config that issued the GET.

- `requestKey : Config -> String` — `Page/Bookshelf.elm:173-181`. Includes the profile handle, since
  `/library` and `/u/ada/library` are different requests through the same `apiName`.
- Both request paths tag the message — `Page/Bookshelf.elm:206`, `:211`.
- `update` drops any response whose key ≠ the current config's key — `Page/Bookshelf.elm:241-249`.
- `requestKey` is exposed so tests build messages via the real function, not string literals.

**Tests** — `frontend/tests/NavigationProgramTest.elm`, describe block "navigate away mid-load
(Issue #274)":

- `navigate_away_mid_load: a Library response arriving after routing to the Antilibrary is discarded`
  — asserts the premise (library GET genuinely in flight) and the invariant (antilibrary stays `Loading`).
- `navigate_away_mid_load: the Antilibrary does not render the stale Library book` — the user-visible consequence.
- `navigate_away_mid_load: the response the current bookshelf asked for is still applied` — non-vacuity
  guard, so the fix can't degenerate into "discard everything".
- `navigate_away_mid_load: Reading Pile and Looking for a Home hold independent Loading state`.

Both stale-response tests failed before the fix with real assertion failures (not compile errors), and
fail again when `requestKey` is deliberately collapsed to a constant — the discrimination is
load-bearing in both directions.

**Blast radius:** changing the `Msg` shape touched three existing test call sites
(`UpdateTest.elm`, `SessionExpiryTest.elm`, `TestHelpers.elm`). No production module other than
`Page/Bookshelf.elm` changed.

### Carried forward

- **`ReadingPile` / `LookingForHome`:** the hazard is structurally impossible for them — each is the
  sole route behind its own `Page` constructor, so the existing constructor match already discards a
  post-navigation response. Only the precondition is asserted here. Driving `BooksLoaded` directly to
  prove the discard behaviourally needs `Msg(..)` exposed, which is **#271's** deliverable
  (`ReadingPile.elm:3`, `LookingForHome.elm:3` are opaque today); not changed here to avoid a merge
  conflict. If a second route is ever added behind either constructor, they inherit this same defect
  and need the same request-key treatment.
- **Browser E2E remains `n/a`** as the issue specified — timing a mid-flight navigation in Playwright
  is inherently flaky, and the program test proves the invariant deterministically.
- **`just verify`** could not be run end-to-end in this worktree: `lint-elixir` aborts because the
  worktree has no `deps/` installed (`Unknown dependency :ecto given to :import_deps`). This is
  worktree setup, not the diff — the change touches no Elixir, proto, or dbt surface. The relevant
  slices (`just lint-elm`, `just test-elm`) both pass.
