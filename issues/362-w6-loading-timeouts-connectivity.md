# Issue #362: Loading is not empty — bounded requests and a connectivity banner

## Summary
A hung or failed shelf request currently renders as an *empty bookcase*: `Page.Bookshelf` gives `Loading` the same branch as an empty shelf, every `Api.elm` request has `timeout = Nothing` so a hung connection never resolves, and the shell says nothing when the browser goes offline. Give `Loading` a state of its own, bound every request in time, and surface connectivity globally on the `handleSessionExpiry` architecture.

## User Stories
US-16.2.1 (handle network failures gracefully). Wave 6 item 6d of epic #316.

## Goal
A reader who loses their connection, or whose request hangs, is told so — in that order of speed: the banner immediately, the loading skeleton while the request is in flight, a bounded failure state within seconds. No state of the network can render as "you have no books".

## Scope Check
- More than 3 controllers? No — frontend only, zero Elixir.
- More than 2 new endpoints? No — none.
- More than ~300 lines of production code? Roughly 250 (Api timeout constants + 80 field edits, one Bookshelf view function + helper, Main connectivity wiring, CSS).
- Unrelated concerns combined? No — all three are the same defect seen at three altitudes: *the app renders a claim it cannot support while the network is not answering.*

## Wiring
Router wiring: includes wiring — user-facing on completion. The loading skeleton, the timeout-bounded failure state and the connectivity banner are all reachable in the running app with no follow-up issue.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-16.2.1 — a failing/hanging API call is communicated clearly | `Api.elm` request records → page `RemoteData` field → page view branch. Before this issue: `Page/Bookshelf.elm:575` routed `Loading` to `viewBookshelfFromShelves model []`, and all 80 `Http.request` records carried `timeout = Nothing`, so the `Failure` branch was unreachable for a hung connection | Offline shelf navigation rendered an empty bookcase, 2026-07-30 (epic #316). Re-driven 2026-08-01 against a deliberately hanging stub server: skeleton at t=0, failure copy at t≈15 s, offline banner on the `offline` event | ✅ | built in-scope |

Verdict: ✅ implemented (built end-to-end + observed live).

## Technical Requirements

### 1. `Loading` must never share a branch with `Success []`
Every `RemoteData` consumer must render a loading state that is *structurally and visually* distinguishable from an empty success. `Page/Bookshelf.elm` is the site: `Loading` shared `viewBookshelfFromShelves model []` with `NotAsked`, and an empty bookcase is what `Success []` also looks like.

Two changes, not one:
- **`init` must not claim `Loading` when it issues no request.** Without a token no request is sent, yet `shelves` was set to `Loading` — a promise nothing will keep. That state now depends on the command actually issued, which is what makes `NotAsked -> empty bookcase` the honest branch and keeps the anonymous page unchanged.
- **`Loading` gets `viewLoadingBookshelf`**: a bookcase of skeleton spines, `aria-busy="true"`, `role="status"`, its own `data-testid`, and copy naming the shelf being fetched.

### 2. Bounded requests
`Api.elm` gains two named timeouts and no bare `Nothing`:
- `standardTimeout` = 15 s — every JSON request. A request that has not answered in fifteen seconds is not going to; below that the reader is still plausibly waiting on a slow network rather than a broken one.
- `uploadTimeout` = 120 s — the one request with a file body (`putFileToR2`). Its clock measures bytes crossing the wire, not a stalled server, so the standard bound would cancel healthy large uploads on slow connections.

`scripts/check-http-timeouts.sh` gates it: a new `Http.request` with `timeout = Nothing` fails the build.

### 3. Shell connectivity banner
Built on the `handleSessionExpiry` architecture — a global, cross-cutting condition surfaced once from the shell, not re-implemented per page:
- inbound port `connectivityChanged : (Bool -> msg) -> Sub msg`, fed by `window.addEventListener("online"/"offline")` in `apps/core/assets/js/app.js`, plus one `navigator.onLine` send at boot;
- `Main.Model.connectivity : Connectivity` (`Online | Offline`) — a two-constructor type rather than a `Bool` field, so the view cannot read it as anything else;
- rendered above the nav in `Main.view` with `role="status"` and `aria-live="polite"`.

## Reviewer Context
- **`scripts/check-session-expiry-coverage.sh` reads `Api.elm` by regex** to decide which endpoints are mandatorily authenticated (`headers = authedHeaders …` / `headers = [ Http.header "Authorization" …`). Adding a `timeout` field must not disturb the `headers =` lines or the `Authed` wrapper: the gate's roster is a set difference, and shrinking it silently is the exact rot it exists to prevent. It must stay at 68 endpoints / 24 pages.
- **`authedExpect` is built on `expectStringResponse`** deliberately (#361) so a 401 is claimed *before* the endpoint's own resolver. Nothing here refactors that.
- **`TestHelpers.libraryEffects` calls `Bookshelf.mutationToken`** rather than mirroring it (#332). The `init` change here touches neither.
- `elm-review --fix` narrows `Msg(..)` back to `Msg` when no test consumes the constructors — `Page.Bookshelf` already exposes `Msg(..)` and must keep it.
- `scripts/check-orphan-classes.sh` cannot see classes built inside a computed `class (if … then … else …)` expression (#356); `scripts/check-css.sh` misses a base rule placed *after* its own modifier at equal specificity (#365). Every class added here is a literal and every base rule precedes its modifiers, and the rendered result was checked by computed style in a browser rather than by the gates alone.

## Test Audit

Format B (feature issue, one user story).
Legend: ✅ real coverage · ⚠️ shallow · ❌ missing · n/a not applicable.

| Layer | US-16.2.1 happy | US-16.2.1 sad | Where |
|-------|-----------------|---------------|-------|
| 1. API calls | ✅ `ApiTimeoutTest` — every `Http.request` in `Api.elm` carries a bounded timeout; `standardTimeout`/`uploadTimeout` values asserted | ✅ same suite: the file-body endpoint is the only one on the long bound | `frontend/tests/ApiTimeoutTest.elm`, `scripts/check-http-timeouts.sh` |
| 2. Auth & middleware guards | n/a — no endpoint's auth changes | ✅ regression: `scripts/check-session-expiry-coverage.sh` still 68 endpoints / 24 pages | gate output |
| 3. DB interactions | n/a — frontend-only change | n/a | — |
| 4. Event flow / lifecycle | n/a — no events emitted | n/a | — |
| 5. Oban jobs | n/a | n/a | — |
| 6. External service calls | n/a | n/a | — |
| 7. Storage | n/a | n/a | — |
| 8. Cache | n/a | n/a | — |
| 9. dbt models | n/a | n/a | — |
| 10. Elm state machine | ✅ `bookshelf_loading_shows_a_loading_state`, `no_token_is_not_asked_not_loading` | ✅ `bookshelf_loading_is_not_the_empty_state`, `bookshelf_empty_is_not_the_loading_state`, `connectivity_banner_*` | `frontend/tests/Page/BookshelfProgramTest.elm`, `frontend/tests/ConnectivityTest.elm` |
| 11. Operational metrics | n/a — covered by SLO gate | n/a | `scripts/check-slo-gate.sh` |
| 12. Performance & usability | ✅ live drive: skeleton at t=0, bounded failure at t≈15 s, screenshots | ✅ same drive: offline banner | issue Progress Notes |
| 13. Cost tracking | n/a — $0.00 per US-16.2.1 §15 | n/a | — |

Punch list: none outstanding.
Verdict: ✅ GREEN — 0 ❌, 0 ⚠️.

## Definition of Done
- [x] `Page.Bookshelf` renders `Loading` distinctly from `Success []` — evidence: `frontend/tests/Page/BookshelfProgramTest.elm "bookshelf_loading_is_not_the_empty_state"` + mutation probe (restore the shared branch → 3 tests red, transcript in Progress Notes)
- [x] Every `Api.elm` request is bounded in time — evidence: `bash scripts/check-http-timeouts.sh` → `OK: all 80 Http.request record(s) in frontend/src/Api.elm are bounded`
- [x] The bound is demonstrated by elapsed time, not by a changed field — evidence: live drive against a hanging stub, failure copy rendered at t=15.0 s (Progress Notes)
- [x] The shell announces loss of connectivity — evidence: `frontend/tests/ConnectivityTest.elm` (5 tests) + live screenshot `connectivity-banner-offline.png`
- [x] `scripts/check-session-expiry-coverage.sh` still exit 0 with an undiminished roster — evidence: `OK: all 24 pages … (68 such endpoints in Api.elm)`
- [x] #359's persist-first probe still reddens — evidence: probe transcript in Progress Notes
- [x] Every behaviour has a validation path — unit/program tests above, plus a live drive for the two user-facing surfaces
- [x] Tests written and passing — evidence: `npx elm-test` → `Passed: 1489, Failed: 0`
- [x] Standards compliance — evidence: `elm-format --validate` clean, `npx elm-review` clean, `check-css.sh` 0 problems, `check-orphan-classes.sh` orphans 88 (unchanged)
- [x] **Test audit (embedded above) is GREEN** — 0 ❌, 0 ⚠️
- [ ] **`completion-audit` skill passed on the integrated branch** — deferred to the epic's integration pass (#316)
- [ ] **Meets the Completion Bar** — deferred to the epic's integration pass (#316); this issue's own deliverables are driven live above

## Dependencies
- #361 (`Authed` wrapper + the session-expiry gate) — the timeout sweep must not disturb either.
- #332 (`mutationToken` read-only guard), #360 (`Arrival`/`StoredAuth`), #359 (persist-first login) — all merged underneath.

## Agent Assignment
elm-agent.

## Progress Notes

### The `RemoteData` census (every consumer, not a sample)

37 modules under `frontend/src/` pattern-match `RemoteData`, containing **56 `Loading ->` branches**. Two questions were asked of every one of them.

*Does `Loading` render text-identical to a sibling branch?* Five did:

| Site | Shares with | Verdict |
|------|-------------|---------|
| `Page/Bookshelf.elm:575` | `NotAsked@572` — `viewBookshelfFromShelves model []` | **the defect** — an empty bookcase, which is also what `Success []` looks like. Fixed. |
| `Page/Login.elm:665` | `Success _@671` — `span [ class "spinner spinner--small" ]` | correct: the button keeps spinning through the redirect that follows a successful login. |
| `Page/Login.elm:719` | `Success _@722`, `Failure _@800` — `True` | correct: a `disabled` predicate, not a view. |
| `Page/Upload.elm:901` | `Success _@907` — the `upload-loading` block | correct: commit-in-flight and commit-succeeded both mean "the pipeline is still working". |
| `Types/RemoteData.elm:39` | `NotAsked@36`, `Failure _@42` — `default` | correct: that is what `withDefault` means. |

*Does `Loading` render any loading affordance at all?* 42 of 56 contain a spinner/skeleton/"Loading"; the other 14 were read individually — 11 are `"Saving…"` / `"Resetting…"` / `"Preparing your export…"` disabled buttons (a loading state, just not matching the word), 2 are boolean `disabled` predicates, 1 is `RemoteData.withDefault`. **One genuine conflation, in `Page.Bookshelf`.**

Two smaller findings recorded rather than fixed here (out of scope, see below): `Page/Bookshelf/ReadingPile.elm:297` renders its loading text inside `reading-pile__empty-msg`, the *empty* state's class — the words differ but the styling says "empty"; and `Page/Profile.elm:64` uses a bare `Loading…` where the rest of the shelf family now has a skeleton.

### Probe: `Loading` and `Success []` are distinguishable

`Page/Bookshelf.elm`, `Loading -> viewLoadingBookshelf model` reverted by Edit to `viewBookshelfFromShelves model []` (the original defect):

```
✗ bookshelf_loading_shows_a_loading_state
✗ bookshelf_loading_is_not_the_empty_state
✗ bookshelf_empty_is_not_the_loading_state
✗ profile_shelf_loading_names_whose_shelf
✗ token_is_loading
Passed: 1467   Failed: 5
```

Restored (`grep -c viewLoadingBookshelf src/Page/Bookshelf.elm` → 3): `Passed: 1483, Failed: 0`.

The replaced test was `bookshelf_loading_state: before HTTP response arrives, empty bookcase is shown`, asserting `Selector.class "bookcase"` — true in `Loading`, in `Success []` and in `Success [book]` alike. It passed throughout the defect's life and would have passed after any repair.

### Probe: the timeout gate sees what the suite cannot

`Page/ThirdSpaces.elm` `timeout` reverted to `Nothing` by Edit:

```
scripts/check-http-timeouts.sh → FAIL: 1 unbounded HTTP request(s)   (exit 1)
npx elm-test                   → Passed: 1483, Failed: 0
```

1,483 green tests say nothing about it: `elm-program-test` resolves simulated effects itself and never reads the `timeout` field.

### Live drive — 2026-08-01

Built assets (`node apps/core/assets/build.js`) served against a stub API that **accepts the connection for `GET /api/bookshelves/*` and never answers** — the failure the bound exists for. Signed in as `@ada`.

⚠️ Recorded because it cost an hour and will cost the next person the same: the driving tab is reported **occluded** (`visibilityState: "hidden"`, `hasFocus: false`, **zero `requestAnimationFrame` callbacks in 3 s**). Elm's virtual-dom schedules every repaint through rAF, so the model advanced while the DOM stayed frozen on a minutes-old frame — three "the timeout never fired" observations were that stale frame, not the app. This is #359's condition, met again in the harness rather than the product. The fix was a `requestAnimationFrame → setTimeout` shim injected into `index.html` by the stub; it changes only *when* frames are scheduled. **A screenshot forces a frame, so screenshots and DOM reads disagree — do not trust either alone in a headless tab.**

**Timeout, measured end to end** (XHR `send` → failure copy in the DOM):

| Observation | Value |
|---|---|
| `xhr.timeout` on the Elm-issued shelf request | `15000` |
| XHR `send` → `timeout` event (page clock) | `15.002 s` (10:32:19.664 → 10:32:34.666) |
| `send` → loading skeleton rendered | `793 ms` (41 placeholder spines, "Fetching your Library…") |
| `send` → failure copy rendered | `16 798 ms` |
| empty-bookcase state at any point | **absent** (`bookshelf-empty` never present) |

What the reader sees: a bookcase of shimmering placeholder spines under "Fetching your Library…", replaced after fifteen seconds by *"Your library is taking too long to arrive. The library may be busy — please try again."* Before this issue the same request produced an empty bookcase, for ever.

**Connectivity banner** — `navigator.onLine` flipped to `false` and the real `offline` window event dispatched (exactly what a browser losing its connection does):

```
bannerPresent: true   role: "status"   aria-live: "polite"   aboveNav: true
text: "You are offline. The Stacks can't reach the library right now — anything
       already on screen stays put, and this will clear as soon as you reconnect."
```

Then the founding case, with the API process actually stopped so the request fails for real: navigating to a shelf while offline renders **"The library is unreachable. Check your connection, then try again."** with the banner above it and no empty bookcase (`bookshelf-empty` absent, `bookshelf-loading` absent). On `online`, `bannerPresent: false`. This also proves the two hops no Elm test reaches: the JS↔Elm port name matches, and `update` writes the field `view` reads.

Screenshots: `01-bookshelf-loading-skeleton.jpg`, `02-timeout-failure-state.jpg`, `03-connectivity-banner-offline.jpg`, `04-offline-shelf-navigation.jpg`.

**Fixed because of the drive, not the tests:** the first skeleton row held twelve spines and filled only half the bookcase width, so the loading state read as an *emptying* shelf. Row lengths now fill `bookcaseInnerWidth`. No test could have seen this.

### Suites and gates

```
npx elm-test                              Passed: 1483, Failed: 0   (baseline 1467, +16)
npx elm-review --config elm-review        I found no errors!
npx elm-format --validate src/ tests/     []
scripts/check-http-timeouts.sh            OK: all 91 HTTP request(s) … are bounded in time.
scripts/check-session-expiry-coverage.sh  OK: all 24 pages … (68 such endpoints in Api.elm)   [unchanged]
scripts/check-css.sh                      743 rule(s), 0 problem(s), 0 collision(s)
scripts/check-orphan-classes.sh           orphans: 88 (0 unstyled, 88 verified test hooks)    [unchanged]
scripts/check-prose-assertions.sh         No risky prose negative assertions (40 checked)
scripts/check-e2e-vacuous-guards.sh       ✓ No vacuous E2E assertion guards
scripts/check-admin-token-routing.sh      All 6 admin token call site(s) use adminTokenFor
```

#359's persist-first probe still bites: removing `PersistAuth` from `Main.loginEffects` reddens
`persist_first_no_animation_signal`, `persist_first_before_any_animation`, `persist_first_is_first`
and two more (5 failures); restored, 1483 green.

### Out of scope — for the epic to triage

1. **No gate ties Elm port names to `app.js`.** A typo in either makes `app.ports.X` undefined and the `if (app.ports && …)` guard skips the block **silently** — the "built but not wired" defect class, and the only unprotected hop in the connectivity chain. A set-difference check over `port X` in `frontend/src/**` vs `app.ports.X` in `apps/core/assets/js/app.js` would close it.
2. `Page/Bookshelf/ReadingPile.elm:297` renders its loading text in `reading-pile__empty-msg` — the empty state's own class.
3. `Page/Profile.elm:64` renders a bare `Loading…` where the shelf family now has a skeleton.
4. `ConnectivityChanged` deliberately triggers no refetch. Whether a reconnect should retry the failed page is a product decision, not a bug.
