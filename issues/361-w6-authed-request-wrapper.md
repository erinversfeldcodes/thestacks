# Issue #361: W6 child — An authed request whose type forces 401 handling, and a gate that discovers who forgot

## Summary
Child of epic #316, Level 2 (item 6c). Three settings write-forms answer a mid-form 401 by telling the reader to try again — `Page/Settings/Password.elm:61`, `Profile.elm:89`, `Notifications.elm:49`. That is a lie: the session is gone, retrying cannot work, and on the profile form the reader is asked to retype the current password they entered to authorise an email change. Driven live 2026-07-30.

The fix is not "remember to check for 401 on these three pages". It is an `Api` request type that cannot be called without naming a 401 handler, plus a gate that **derives** which pages owe one instead of being handed a list.

## User Stories
US-14.3.2 (session expiry), US-17.3.1 (notification preferences), US-14.2.1 (sign in — the return-to-page half).

## Goal
A page that ignores session expiry does not compile. Where a page still reaches a legacy endpoint, a source-level gate that discovered it fails the build. Both, because the type covers the endpoints that have been converted and the gate covers the 63 that have not.

## Scope Check
One Elm module (`Api.elm`) plus three pages under `Page/Settings/`, one gate script, plus the `Main.elm` routing those three pages require. Zero controllers, zero endpoints, ~330 lines of production Elm of which ~180 is the wrapper and its documentation. Under the bar.

⚠️ **Contended files.** `Api.elm` goes to **#362** (request timeouts) after this; `Main.elm` belongs to **#360**. The `Main.elm` work here is unavoidable — changing the arity of three `update` functions does not compile otherwise — and was approved by the epic on 2026-08-01 with the merge order flipped to **361 → 360** so it lands first. It is three additive `case` branches mirroring the existing `Consent`/`AuditLog` shape, plus the expiry-redirect fix below.

## Wiring
Router wiring: none new. User-facing on completion: a session that dies mid-form takes the reader to the sign-in gate with the "session expired" notice — and back to the page they were on once they sign in — instead of showing them a retry button that cannot work.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-14.3.2 session expiry on a settings write-form | `Password.elm:61` / `Profile.elm:89` / `Notifications.elm:49` all render retry copy on `Err` | 401 → "Please try again" (2026-07-30) | ❌ | build in-scope |
| US-14.2.1 return to the page you were on after an expiry | `forceSessionExpiry` pushes `/login`; `UrlChanged` recomputes `redirectAfterLogin` from the ARRIVING route | asked-for page lost | ❌ | fix in-scope (#359 finding) |

## Technical Requirements
1. **`Api.Authed err ok msg`** — an opaque type carrying the token, `onExpired : msg` and `onResult : Result err ok -> msg`, built only via `Api.authed token { onExpired = …, onResult = … }`. A record literal must supply every field, so there is no wildcard, no default and no `_ ->` branch. This is stronger than an exhaustiveness check, which `_ ->` satisfies.
2. **The 401 is claimed before the endpoint's resolver runs.** `authedExpect` is built on `expectStringResponse`, not `expectJson`/`expectWhatever`, so "session expired" cannot arrive at a page disguised as `BadStatus 401` inside an error value the page may ignore.
3. **Convert the three write-forms** to `( Model, Cmd Msg, OutMsg )` with `OutMsg = NoOut | SessionExpired`, matching the 21 pages that already do this. Route them in `Main` to `handleSessionExpiry` (the re-check net, which adopts a sibling tab's newer token before logging anyone out).
4. **The reflection gate must discover, not be told.** Roster = a set difference over `Api.elm` × `src/Page/`, recomputed every run.
5. **Close the `redirectAfterLogin`-on-expiry gap** (#359 finding): an expiry bounce is a bounce, and must remember the page it bounced off.

## Reviewer Context
- BOOTSTRAP: `just bootstrap-worktree` from inside the worktree, then `git merge --ff-only feat/campaign-w6-316` — **LOCAL, UNPUSHED**; no `git fetch`, no `origin/`.
- **NEVER bare `mix`** — `just run mix …`. **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`.
- **Mandatory vs optional auth is the load-bearing distinction.** `authHeaders : Maybe String -> …` endpoints (`getProfile`, `getListings`, `getBlogPosts`, `searchUsers`) are valid anonymously, so their 401 is NOT an expiry signal. Routing one would log out an anonymous reader. The gate excludes them by reading how the header is built.
- **A 403 is not a 401 here** — 403 is the age-gate and stays local (`Api.isUnauthorized`'s existing contract).
- `Main.Model` embeds an unconstructable `Nav.Key`, so anything left inline in `Main.update` cannot be unit-tested at all. That is why `redirectAfterNavigation` is a named, key-free function — the same treatment `loginRedirectFor`, `adoptExternalAuth` and `resolveRecheck` already get.
- `elm-review`'s `NoUnused.Exports` reviews `src/` and `tests/` together: every new `Api` export needs a test consumer in the same change.
- `NoUnused.CustomTypeConstructorArgs` requires a constructor's payload to be *extracted* somewhere, not merely compared with `Expect.equal`.
- Commit: agent commits are DENIED. Stage; ONE-LINE message (no body/trailers) to the scratchpad `commit-msg-361.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine — the 401 decision | yes | ✅ `frontend/tests/ApiAuthedTest.elm` (10 tests) drives the real `Api.interpretAuthed` with real resolvers over every `Http.Response` shape |
| Elm state machine — page routing | yes | ✅ `frontend/tests/Page/SessionExpiryPagesTest.elm` — 11 new assertions across the three pages, each 401 case paired with a non-401 and a success control |
| Elm state machine — expiry redirect | yes | ✅ `frontend/tests/SessionExpiryTest.elm` — 5 assertions on `Main.redirectAfterNavigation` (2 behaviour, 3 controls) |
| Source-level invariant | yes | ✅ `scripts/check-session-expiry-coverage.sh`, wired into `scripts/lint-elm.sh`; four independent failure modes, each probed |
| auth & middleware guards (server) | no | n/a — this is entirely SPA-side; the server's 401 behaviour is unchanged |
| DB, events, Oban, external services, storage, cache, dbt | no | n/a — no server, schema or pipeline surface is touched |
| operational metrics, performance & usability, cost tracking | no | n/a — covered by the SLO gate (`scripts/check-slo-gate.sh`) |
| E2E | no | n/a — an expiry E2E needs a token the server will reject mid-session; the existing `e2e/tests/auth.spec.ts` logout path already covers `forceSessionExpiry`'s port + redirect, and the seam this issue changes is above it |

Verdict: GREEN. 0 ❌, 0 ⚠️.

## Definition of Done
- [x] `Api.Authed` exists and cannot be constructed without `onExpired` — evidence: `frontend/src/Api.elm` `type Authed err ok msg`; `Api.authed` takes a record with both handlers; call sites in all three pages
- [x] The 401 is claimed before the endpoint resolver — evidence: `elm-test tests/ApiAuthedTest.elm` → `10 tests, 0 failures`; probe `statusCode == 401` → `403` → **4 failed** incl. the `a_403_stays_local` control
- [x] Three write-forms converted and routed — evidence: `Password.elm`, `Profile.elm`, `Notifications.elm` return `( Model, Cmd Msg, OutMsg )`; `Main.elm` routes each to `handleSessionExpiry`; `SessionExpiryPagesTest` 11 new assertions green
- [x] **The reflection gate discovers rather than is told** — evidence: `scripts/check-session-expiry-coverage.sh --list` → `68 endpoints, 25 pages in scope`, no page named in the script; a NEW page (`Page/ProbeDelete.elm`) making an authed call was caught with no registration step
- [x] Gate probed on all four failure modes — evidence: undeclared → FAIL; declared-not-exposed → FAIL; exposed-never-returned → FAIL; `onExpired` unrouted → FAIL; correctly wired → OK (exit 0)
- [x] **The gate catches what the suite cannot** — evidence: unwiring `Settings/Password.elm`'s `onExpired` reintroduces the defect verbatim; `elm-test` → `1427 passed, 0 failed`; gate → exit 1
- [x] Expiry bounce remembers the page it bounced off — evidence: `Main.redirectAfterNavigation` + 5 tests; probe (delete the `sessionExpiring` branch) → exactly 2 red, 3 controls green
- [x] Suites green — evidence: `npx elm-test` → `1427 passed, 0 failed`; `elm-review src/ tests/` → `I found no errors!`; `elm-format --validate src/ tests/` → `[]`
- [x] Gates green — evidence: `check-orphan-classes.sh` → `orphans: 88` (baseline 88, zero added); `check-prose-assertions.sh` → `37 checked, 12 allowlisted`, the new negative inspected and `ok`; `check-session-expiry-coverage.sh` → exit 0
- [ ] Driven live on a preview stack — deferred to the epic's wave drive (this branch has no deployed stack of its own)

## Dependencies
#359 (`AuthState`, merged). Contends with #360 on `Main.elm` (merge order flipped to 361 → 360) and #362 on `Api.elm`.

## Agent Assignment
elm-agent.

## Progress Notes
- 2026-08-01: Built. Wrapper + 5 endpoint conversions + 3 page conversions + gate + `Main` routing + the #359 redirect fix. Out-of-scope findings recorded below.
- **Out of scope, for follow-up:** 63 of the 68 mandatorily-authenticated `Api` endpoints still take a bare `String` token, so their 401 handling is protected by the gate rather than by the type. Converting them is mechanical but well past this issue's budget, and `Api.elm` is contended by #362.
- **Out of scope, for follow-up:** `frontend/tests/Page/SessionExpiryPagesTest.elm` remains a hand-picked roster of eight pages (now eleven). It is no longer the coverage claim — the gate is — but the two could be reconciled.
