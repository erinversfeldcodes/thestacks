# Issue #360: W6 child — Three collapses in the app shell: page title, arrival reason, stored auth

## Summary
Child of epic #316, Level 2, built directly on **#359**. Three ad-hoc, hand-maintained representations in `frontend/src/Main.elm` are collapsed into one derivation each:

1. **`document.title` is derived from `Route`, not from the `Page` actually rendered** — so it names a page the reader is not looking at in six places.
2. **The reason a reader is standing at the login door is spread across six booleans, five `Login` inits and two view predicates** — mutually-exclusive reasons that nothing prevents being true at once.
3. **`decodeFlags` answers `Maybe Auth`, so an unreadable stored credential is indistinguishable from a deliberate sign-out** — the reader is silently logged out and told nothing, which is why the private-session auth bug was hard to diagnose.

## User Stories
US-14.2.1 (sign in), US-14.3.2 (session expiry), US-14.4.1 (account deletion farewell). Accessibility: the document title is the first thing a screen reader announces on navigation, and the only page identity a browser tab, a bookmark or a history entry keeps.

## Goal
One derivation per concept, each with a single source of truth:

- `pageTitle : Page -> String` — the title is a function of what is on screen, so it cannot drift from it.
- `Arrival = Fresh | SessionExpired { draftSaved } | AccountDeleted | ForgotPassword | StoredSessionUnreadable String` — one value, so two arrival reasons at once stops being writable.
- `StoredAuth = NoStoredAuth | CorruptStoredAuth String | ValidStoredAuth Auth` — three boot outcomes, three constructors, and the corrupt one is **surfaced to the reader** rather than silently read as "logged out".

## Scope Check
- Controllers touched: 0 (frontend only). → under the bar.
- New endpoints: 0. → under the bar.
- Production LOC: `Main.elm` + `Page/Login.elm` + ~4 lines of `apps/core/assets/js/app.js` + one CSS rule. The title case expression is large but mechanical (one branch per `Page` constructor, replacing one branch per `Route`). → under the bar.
- Unrelated concerns: no — all three are the same defect class (a hand-maintained second representation of something the app already knows) in the same module.

## Wiring
Router wiring: none new. User-facing on completion — the browser tab, screen-reader page announcement and history entries name the page actually rendered; a reader whose stored sign-in cannot be read is told so instead of being silently signed out.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-14.2.1 sign in | built: `Page/Login.elm` → `Main.completeLogin` (#359) | driven under #359 | ✅ | built |
| US-14.3.2 session expiry notice | built: `Main.forceSessionExpiry` → `Login.expiredInit` | driven under #173/#180 | ✅ | built |
| US-14.4.1 account-deletion farewell | built: `Main.handleAccountDeleted` → `Login.farewellInit` | driven under #188 | ✅ | built |

All three stories are BUILT; this issue changes their representation, not their behaviour. The one genuinely new behaviour — telling the reader their stored credential was unreadable — has no prior story and is specified below.

## Technical Requirements

### 1. Derive the title from `Page`
`view` calls `pageTitle model.route`. `Route` is what was *asked for*; `Page` is what was *built*. They disagree, today, at six sites:

| # | Site | Page rendered | Title claimed |
|---|------|---------------|---------------|
| 1 | `initPage` auth bounce (`Main.elm:658`) | `PageLogin` | the asked-for protected route ("Add a Book", "Library", …) |
| 2 | `initPage` admin gate (`Main.elm:661-667`) | `PageAdminGate` | the admin surface behind the gate |
| 3 | `initPageAuthenticated` owner guard (`Main.elm:929,940,968`) | `PageNotFound` | the admin surface |
| 4 | `initPageAuthenticated` age-gating guard (`Main.elm:955`) | `PageNotFound` | "Book Moderation" |
| 5 | `UserMenu.SignOut` (`Main.elm:2514`) | `PageLogin` | the page they signed out from |
| 6 | `handleAdminSessionExpiry` (`Main.elm:3436`) | `PageAdminGate` | the admin surface — and **permanently**, because this path never changes the URL |

Plus content drift where the route cannot know what is on the page: `ProfileShelf` is titled "Reader" though a named bookshelf is rendered, `BookDetail` is titled "Book" though the book's title is loaded, `BlogEdit`/`BlogNew` collapse into one editor page.

Requirement: `pageTitle : Page -> String`, exhaustive over `Page`, reading sub-model content where the page has it (bookshelf label, book title, profile handle, editor mode, login arrival/mode). No `Route` argument — if a title needs route context, the `Page` constructor must carry it (`PageAdminGate` already does).

### 2. Collapse the arrival reason
Today, "why is this reader at the login door" is:

- **six booleans** — `Main.sessionExpiredNotice`, `Main.draftSavedNotice`, `Main.accountDeletedNotice`, `Login.sessionExpired`, `Login.draftSaved`, `Login.accountDeleted`;
- **five inits** — `Login.init`, `Login.forgotInit`, `Login.expiredInit`, `Login.expiredDraftInit`, `Login.farewellInit`;
- **two view predicates** — `Login.viewSessionExpiredNotice`, `Login.viewAccountDeletedNotice`, each recomputing the same `submitFailed` suppression.

Nothing prevents `sessionExpired && accountDeleted`, or a `draftSaved` with no expiry. Requirement: one `Arrival` value, one `Login.init : Arrival -> Model`, one notice view that cases over it. The `Login`-side booleans and the `Main`-side booleans become the *same* value, passed down, so they cannot disagree.

`ForgotPassword` belongs in the same type: `/forgot-password` is not a page, it is the login card opened for a different reason (`Main.elm:1006-1010`).

### 3. `StoredAuth`, with the corrupt case surfaced
`decodeFlags : Decode.Value -> Maybe Auth` folds three outcomes into two. A stored blob that fails `authDecoder` — the flat-vs-nested shape error recorded in project memory as the private-session auth bug — returns `Nothing`, which is byte-identical to "never signed in". The reader is signed out and told nothing; the app knows why and discards it.

Requirement: `decodeFlags : Decode.Value -> StoredAuth` with `NoStoredAuth | CorruptStoredAuth String | ValidStoredAuth Auth`, the `String` carrying `Decode.errorToString` of the real failure, and the corrupt case raising an `Arrival` the login card renders. `app.js` currently swallows both `JSON.parse` failure and a `localStorage` access failure (private browsing) in one bare `catch` — it must hand the reason to Elm rather than dropping it, or `CorruptStoredAuth` can only ever see half the cases.

## Reviewer Context
- BOOTSTRAP: **`just bootstrap-worktree`** from inside the worktree, then `git merge --ff-only feat/campaign-w6-316` — **LOCAL, UNPUSHED**; no `git fetch`, no `origin/`.
- **NEVER bare `mix`** — `just run mix …`. **`caffeinate -i`** for long suites. **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`.
- ⚠️ **Do not weaken #359.** `Main.loginEffects` carries a ⛔ comment (`PersistAuth` first, `PlayDoorAnimation` last, all from the single update that decodes the 200). `frontend/tests/PersistFirstLoginTest.elm` must stay green **and its probe must still redden**. `Arriving` and `Authenticated` must stay indistinguishable to `currentAuth`; `settleArrival` must stay total and idempotent.
- ⚠️ **File ownership:** `Main.elm` and `Page/Login.elm` are this issue's. `Api.elm` and `Page/Settings/*` belong to **#361** — do not touch them.
- ⚠️ Elm pages with tests must expose `Msg(..)`; `elm-review --fix` narrows it back if no test consumes it.
- ⚠️ `frontend/css/main.css` is the only stylesheet source. `bash scripts/check-orphan-classes.sh` (baseline 88, add **zero**) and `bash scripts/check-css.sh`. The orphan gate is blind to computed `class (if …)` forms (#356) — verify any such rule by hand.
- ⚠️ `scripts/check-prose-assertions.sh` misses `ensureViewHasNot` — pair every negative assertion with a positive control.
- The title is not decoration: `Browser.Document.title` is what a screen reader announces on navigation and what a browser tab, bookmark and history entry keep.
- Commit: agent commits are DENIED. Stage; ONE-LINE message (no body/trailers) to the scratchpad. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine — title | yes | ✅ `frontend/tests/PageTitleTest.elm` — the six drift sites each asserted at the `Page` that is actually built, plus an exhaustiveness sweep proving no page falls back to a placeholder. Probe: reintroduce drift site 2. |
| Elm state machine — arrival | yes | ✅ `frontend/tests/ArrivalTest.elm` — one notice per arrival, and a **negative control paired with a positive** for each (the expiry arrival shows the expiry notice AND not the farewell). Probe: make `Login.init` ignore its argument. |
| Elm state machine — stored auth | yes | ✅ `frontend/tests/StoredAuthTest.elm` — flat-valid → `ValidStoredAuth`; nested-under-`user` → `CorruptStoredAuth` **and the login card tells the reader**; empty flags → `NoStoredAuth`. Probe: return `NoStoredAuth` on decode failure (the old behaviour). |
| Elm — #359 regression | yes | ✅ `frontend/tests/PersistFirstLoginTest.elm` unchanged in substance and still probe-sensitive. |
| API calls / auth guards / DB / events / Oban / external / storage / cache / dbt / metrics / perf / cost | no | n/a — frontend-only representation change; no request, schema, event or job is touched. |

## Definition of Done
- [x] `pageTitle : Page -> String`; all six drift sites named above produce the title of the page rendered — evidence: `frontend/tests/PageTitleTest.elm` (14 tests); probe — naming the gated route in the `PageAdminGate` branch reddens `drift_2_admin_gate` + `drift_6_admin_reauth` (1435/2). Live: `/upload` signed out → login card, title **"Sign In — The Stacks"**, URL still `/upload` (the pre-#360 preview tab at the same path reads "Add a Book — The Stacks").
- [x] `Arrival` replaces six booleans, five inits and two view predicates; two arrival reasons at once is a compile error — evidence: `frontend/tests/ArrivalTest.elm` (14 tests); probe — `Login.init` ignoring its argument reddens 9 tests across three suites; compile probe — `{ card | sessionExpired = True, accountDeleted = True }` → *"The `expiredCard` record does not have a `accountDeleted` field"*, and `Login.AccountDeleted { draftSaved = True }` → *"TOO MANY ARGS"*.
- [x] `decodeFlags → StoredAuth`; a corrupt stored credential is surfaced to the reader, not merely logged out — evidence: `frontend/tests/StoredAuthTest.elm` (9 tests); probe — returning `NoStoredAuth` on decode failure (the `Result.toMaybe` behaviour) reddens 4. Live: a nested-`user` blob at `/login` renders `role="status"` with the copy and `title="… Expecting an OBJECT with a field named \`userId\`"`.
- [x] #359's guarantee intact — evidence: `PersistFirstLoginTest.elm` green; removing `PersistAuth` from `loginEffects` still reddens 5 tests including `persist_first_is_first` and `completeLogin cannot produce an authenticated state without the effect that saves it`.
- [x] Suites green; `check-orphan-classes.sh` zero new; `check-css.sh` clean — evidence: post-#361-reconcile `elm-test` **1467 passed / 0 failed** (1400 baseline → 1437 with #360 → 1464 merged with #361 → 1467 with the seam tests); orphans **88 (0 unstyled)** — unchanged, Elm classes 802→803, CSS selectors 823→824; `check-css.sh` 733 rules, 0 problems; `elm-review` no errors; `elm-format` `[]`; admin-token routing 6/6.
- [x] **#361's guarantee intact after the reconcile** — evidence: `scripts/check-session-expiry-coverage.sh` exit **0** (24 pages, 68 endpoints); its three additive `Settings/{Password,Profile,Notifications}` handlers and `redirectAfterNavigation` present verbatim. Probe: reverting `Page/Settings/Password.elm`'s `SessionExpired` return leaves the gate **FAIL exit 1** while only 1 of 1464 Elm tests reddens — the gate is doing work the suite cannot.
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #316. **Depends on #359** (which left `Main.elm` clean, with no `Arrival`/`StoredAuth` names taken). Level 2 — parallel with **#361**, which owns `Api.elm` and `Page/Settings/*`.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-08-01 from the Wave 6 Level-2 brief, at implementation time. Built the same day on `feat/campaign-w6-316` (local, unpushed), directly on top of #359.

**Counts collapsed.** Title: **43 route branches → 41 page branches**, one per `Page` constructor, `Route` no longer an argument at all; six drift sites closed by construction (`Main.elm`, `pageTitle`). Arrival: **6 booleans → 1 field** (`Main.sessionExpiredNotice`/`draftSavedNotice`/`accountDeletedNotice` + `Login.sessionExpired`/`draftSaved`/`accountDeleted` → `Login.Arrival`), **5 inits → 1** (`init`/`forgotInit`/`expiredInit`/`expiredDraftInit`/`farewellInit` → `init : Arrival -> Model`), **2 view predicates → 1** (`viewSessionExpiredNotice` + `viewAccountDeletedNotice` → `viewArrivalNotice`, which also renders the new fifth reason). Stored auth: **2 outcomes → 3** (`Maybe Auth` → `StoredAuth`).

**A collapse fixed a latent bug.** The three notice booleans were each cleared by `… && newRoute /= Login`, but the protected-route bounce shows the login card **without changing the URL** — so a notice raised on `/library` was never marked delivered. `consumeArrival` asks the page that was built, not the route. Regression-tested by `consumed_by_bounce`.

**Deliberate deviation from the brief, disclosed:** `Arrival` has a **fifth** constructor, `StoredSessionUnreadable String`. The brief specified four and separately required the corrupt stored-auth case be *surfaced*; any other surfacing would have been a seventh boolean, undoing collapse 2. `Arrival` is defined in `Page.Login` (not `Main`) because Elm forbids the cycle — `Main` already imports `Page.Login`, and the type names login-card states.

**`app.js` touched (4 lines, in scope):** its `catch` around `localStorage.getItem` + `JSON.parse` was empty, so *storage threw* (private browsing) and *unparseable blob* both reached Elm as "no auth fields" — indistinguishable from signed out, and invisible to `decodeFlags`. It now passes the reason as `flags.storedAuthUnreadable`. A blob that parses but has the wrong **shape** is caught Elm-side. Between them all three boot outcomes are distinguished.

**Live drive** (built bundle, `node build.js`, served with pushState fallback; console clean): `/nonexistent-page` → "Not Found — The Stacks"; `/upload` signed out → login card at `/upload` titled "Sign In — The Stacks"; switching to the Register tab retitles to "Create Account — The Stacks" **with the URL unchanged** — something a route-derived title structurally could not do; `/forgot-password` → reset form, "Reset Password — The Stacks"; nested-`user` blob at `/library` and at `/login` → bounce + notice + the decoder's real message; clean localStorage → no notice (paired negative). Boot at `/` with the corrupt blob → home page, title "The Stacks", **no notice yet** — the arrival is pending, as designed.

⚠️ **Not drivable, stated rather than glossed:** delivering a *pending* arrival across a **client-side** navigation. The MCP tab reports `visibilityState: "hidden"`, so Elm's rAF-scheduled render is frozen — the URL advanced to `/login` and the DOM stayed on the home page indefinitely. That is the #359 occlusion condition, not a defect here. Covered by `consumed_by_login_card`, `consumed_by_bounce`, `kept_elsewhere`, plus the boot-path live drive above.

### Reconcile with #361 (merge-order change after this issue started)
#361 landed on `feat/campaign-w6-316` first, so this was rebuilt on top of it. One textual conflict in `Main.elm`: #361's new `redirectAfterNavigation` sits immediately before `initPage`, whose signature #360 changed. Both kept verbatim; a cross-reference added noting they fix the same bounce from two directions (#361 remembers the page being left, #360 says why the reader is at the door).

**One genuine semantic coupling, not merely textual.** #361's call site read `sessionExpiring = model.sessionExpiredNotice` — one of the six booleans #360 collapsed. That is the *same fact*, so it is now read from the same value via a named reader, `Login.isSessionExpiry`, beside `draftWasSaved` and for the same reason `Main.currentAuth` is the only reader of `AuthState`. Keeping a seventh boolean would have made "expiry raises the notice but not the redirect" writable again. Value seen at the call site is identical to the old boolean's: both are read before consumption, and `consumeArrival` clears exactly when the old `… && newRoute /= Login` did (route `Login` always builds a card).

⚠️ **The reconcile opened a hole and the probe found it.** Stubbing `isSessionExpiry` to `always False` — the #361 defect restored — left **all 1464 tests green**. #361's five tests call `redirectAfterNavigation` with `sessionExpiring` as a *literal*, so none of them can see the call site's computation, and I had moved that wire. Closed with three tests in `ArrivalTest.elm` (`expiry_predicate_totality`, `expiry_arrival_drives_capture`, `non_expiry_arrival_captures_nothing` — the last a paired control, since the first would also pass under `always True`). Re-probed: the stub now reddens 2.

`SessionExpiryTest.elm` auto-merged; read in full rather than trusted. #361's five tests exercise the key-free `redirectAfterNavigation` and are untouched by this work; #360's three prose edits and the `Login.init` retrofit all survived intact.

**Out-of-scope finding — three login-card notice modifiers are mostly dead CSS.** `.login-card__notice` (0,1,0) at `main.css:5860` sits *after* `.login-card__notice--session-expired` (2635) and `--account-deleted` (2653) at equal specificity, so the base rule's accent green wins `color`/`background`, and its `margin`/`padding` shorthands win too — the intended "calm lamplight amber" of the expiry and farewell notices has been dead on two shipped surfaces. Measured live: computed `background-color` `rgba(74, 124, 89, 0.15)`, not the declared `rgba(184, 134, 11, 0.12)`. **`check-css.sh` misses it**: check C catches a modifier beaten by its base only *under a pseudo-class*; this is the same family with no pseudo-class. Not repainted here (scope lock — it would change two surfaces #360 did not ask about); the new `--stored-session-unreadable` rule therefore declares only `cursor` and `text-decoration`, which the base does not set and which were verified applying live (`cursor: help`, `underline dotted`). Recommend: generalise `check-css.sh` check C to pseudo-class-free base/modifier collisions, then fix all three.

**staff-review verdict: LGTM** (2026-08-01, lead, Mode B on 87d614ef + the reconcile merge). Praise: (a) **a collapse found a latent bug**, which is the argument for doing collapses at all — the three arrival booleans were cleared by `… && newRoute /= Login`, but the protected-route bounce shows the login card **without changing the URL**, so a notice raised on `/library` was never marked delivered and would resurface later. `consumeArrival` now asks the built page instead of inferring from the route. Nobody was looking for that; it fell out of removing the duplication; (b) the title derivation closes six drift sites **by construction** rather than by fixing six call sites — `pageTitle : Page -> String` cannot consult a `Route`, so the bounce, the MFA gate, the owner guard, the ADR-020 refusal, sign-out and `handleAdminSessionExpiry` (whose title was permanently wrong, since it never touches the URL) are all fixed by the type; (c) it fixed `app.js`'s **empty `catch`** so a `localStorage` throw reaches Elm as `storedAuthUnreadable` instead of vanishing — the corrupt case could not have been surfaced without it; (d) compile-probes as evidence: `{ card | sessionExpired = True, accountDeleted = True }` → *"does not have a `accountDeleted` field"*, and `AccountDeleted { draftSaved = True }` → *"TOO MANY ARGS"*. Two arrival reasons at once, and a `draftSaved` detached from the expiry it describes, are now unrepresentable.
**The reconcile is the part worth reading.** #360 built on a pre-#361 base; the merge conflicted in `Main.elm` and the lead aborted rather than hand-resolve Elm it had not written, sending it back per the 2026-08-01 coordination decision. It reported the conflict was **not purely textual**: #361's call site read `sessionExpiring = model.sessionExpiredNotice` — one of the six booleans being collapsed. Rather than reinstate a seventh boolean (which would have made "expiry raises the notice but not the redirect" writable again), it routed both through a named reader, `Login.isSessionExpiry`. Lead-verified: `git diff` over `Api.elm` and `Page/Settings/` between #361's commit and HEAD is **empty** — #361's files are byte-identical.
**⚠️ The reconcile opened a hole, and re-running the probes is what found it.** Stubbing `isSessionExpiry` to `always False` restored #361's defect and left **all 1464 tests green** — because #361's five tests pass `sessionExpiring` as a *literal*, so none of them can see the call site's computation, and #360 had just moved that wire. Closed with three tests in `ArrivalTest.elm`, including `non_expiry_arrival_captures_nothing` as a **paired control** (the positive test alone would also pass under `always True`).
**Lead independent probe on that seam:** severed `isSessionExpiry` after the merge → **1465 passed, 2 failed**, the two new seam tests. Before they existed the identical stub left everything green. Reverted via Edit; `git status` clean, `grep -c` → 1, suite back to 0 failures. The session-expiry coverage gate is exit 0 after the merge.
This is the concrete case for re-running probes after a reconcile rather than trusting a green suite: **two individually-correct changes, and the seam between them untested.** Neither child could have found it alone.
Suites: elm-test **1467/0** (1400 baseline → 1437 #360 → 1464 merged → 1467 with the seam tests); `lint-elm.sh` all green; esbuild bundle builds. #359's persist-first probe still reddens 5; #361's coverage gate still fails on its own defect while only 1 of 1464 tests notices.
**Deviation accepted:** a fifth `Arrival` constructor, `StoredSessionUnreadable String`. The brief asked for four constructors *and* for the corrupt case to be surfaced; any other surfacing would have been a seventh boolean. That is the brief being underspecified, not the agent exceeding it.
**Finding filed as #365:** three login-card notice modifiers have never rendered their declared amber — the base `.login-card__notice` (main.css:5837) sits *after* `--session-expired` (2635) and `--account-deleted` (2653) at equal specificity, so it wins, and its `margin`/`padding` shorthands beat their longhands. Measured live (`rgba(74,124,89,0.15)` where `rgba(184,134,11,0.12)` was declared). `check-css.sh` reports 0 problems because check C only catches base-beats-modifier *under a pseudo-class*. Left unrepainted under scope-lock, correctly.
