# Issue #214: Frontend profile hub — `Page.Profile` + `Route.Profile`

## Summary
The Elm page that renders `/u/:handle`: `Route.Profile String`, a new `Page.Profile` hub
(display name, `@handle`, location, website, and links to the viewer-visible bookshelves),
`Api.getProfile` + the `PublicProfile` decoder, and Main wiring (mirroring the BlogPost
wiring). **The hub compiles and the full elm-test suite is green; a dedicated
`Page.Profile` test does not yet exist.**

## User Stories
- **US-10.5.2** — View a Reader's Public Profile (`docs/user_stories/US-10.5.2-view-profile.md`) — the Elm hub half.

## Goal
Navigating to `/u/:handle` renders the reader's hub with their visible bookshelves as links,
and a ghost/blocked/unknown handle renders a neutral "Reader not found" card — with a 401
escalating to `SessionExpired`.

## Scope Check
- >3 controllers? No (frontend only).
- >2 new endpoints? No (consumes #213's `GET /api/u/:handle`).
- >~300 LOC? No.
- Combines unrelated concerns? No.

## Wiring
- [x] Router/SPA wiring included — `Route.Profile` parses `/u/:handle` (`frontend/src/Navigation/Route.elm:52,95`); Main dispatches to `ProfilePage.init` (`frontend/src/Main.elm:694`). User-facing when complete.
- [ ] Implementation only.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.5.2 — View a Reader's Profile (Elm hub) | `Route.Profile String` (`Navigation/Route.elm:52`) → Main `Profile handle` → `ProfilePage.init maybeToken handle` (`Main.elm:694`) → `Api.getProfile` (`frontend/src/Api.elm:1916`, `PublicProfile` decoder :1873) → `GotProfile (Ok p)` → `Success p` (`Page/Profile.elm:47`); `viewShelves` links to `Route.ProfileShelf handle name` (:130) | 🟡 compiles + full elm-test green; **no dedicated `Page.Profile` test**; not yet browser-live-driven | 🟡 | add `ProfileTest.elm` + live-drive in this issue |

Verdict: 🟡 partial — the page is built and wired; the missing hop is a state-machine test + a live drive proving the hub renders and the "not found" card shows.

## Technical Requirements
- `Route.Profile String` = `s "u" </> string`; `Route.ProfileShelf String String` = `s "u" </> string </> string` (already present, `Navigation/Route.elm:52-53,94-95`).
- `Page.Profile`: `Model { handle, token, profile : RemoteData Http.Error PublicProfile }`; `init maybeToken handle` → `Loading` + `Api.getProfile`; `GotProfile (Ok p)` → `Success`; `GotProfile (Err e)` → 401 ⇒ `SessionExpired` OutMsg, else `Failure e`; `view` renders header (name/@handle/location/website) + `viewShelves`, or "Reader not found".
- `Api.getProfile : Maybe String -> String -> (Result Http.Error PublicProfile -> msg) -> Cmd msg` + `publicProfileDecoder` (`Api.elm:1887`).
- Main wiring mirrors the BlogPost page (`PageProfile` model variant, `PublicProfileMsg`).

## Reviewer Context
- `/u/:handle` is an **Elm SPA route** — served by the `/*path` catch-all; the API is `/api/u/:handle`.
- The `Msg` type must expose `Msg(..)` for the test (project convention: any page with tests exposes `Msg(..)`, see MEMORY — Elm Module Exposing).
- `ProfileShelf` currently lands on the hub as a temporary measure (`Main.elm:701-708`) until #215 builds the read-only browse — a shelf link must never dead-end.
- "Reader not found" is the **same** card for ghost / blocked / unknown — no information leak (the backend already returns an indistinguishable 404).

## Test Audit
FULL 13-layer × US-10.5.2 (Elm-hub scope). The backend layers are #213's; here the load-bearing
layer is **Layer 10 (Elm state machine)**. Legend: ✅ | ⚠️ | ❌ | n/a.

**Framework-layer summary**

| Layer | 10.5.2 (hub) |
|-------|--------------|
| Elixir (backend) | ✅ — owned by #213 (`profile_controller_test.exs`) |
| Elm unit/program | ❌ — no `Page.Profile` test yet |
| E2E | ❌ — dissolved from #218 into this issue's live-drive |

**Existing test inventory (verified by read):** **no** test in `frontend/tests/` references `Page.Profile`, `getProfile`, or `PublicProfile` (`grep` = none). The page compiles under the existing green elm-test run but has zero targeted coverage.

#### Layer 1: API Calls
| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.2 | ❌ `init` fires `Api.getProfile maybeToken handle` — assert the Cmd/decoder round-trips a `PublicProfile`. → **punch #1** | ❌ | ❌ (matrix) `GotProfile (Err 404)` → `Failure` renders "Reader not found" (ghost/blocked/unknown are indistinguishable to the client). → **punch #2** | ❌ |

#### Layer 2: Auth & Middleware Guards
| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.2 | ❌ signed-in vs anonymous `maybeToken` threading into `getProfile`. → **punch #1** | ❌ | ❌ `GotProfile (Err 401)` → `SessionExpired` OutMsg (not `Failure`). → **punch #3** | ❌ |

#### Layer 3: DB · Layer 4: Events · Layer 5: Oban · Layer 6: External · Layer 7: Storage · Layer 8: Cache · Layer 9: dbt
All **n/a** — frontend page; the DB read + gating are backend (#213, US §5–11 all read-path/no-op for the client).

#### Layer 10: Elm Frontend State Machine
| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.2 | ❌ `init` → `Loading` + Cmd; `GotProfile (Ok p)` → `Success p`; `viewShelves` renders one link per visible shelf to `Route.ProfileShelf`. → **punch #1** | ❌ | ❌ `GotProfile (Err _)` non-401 → `Failure` → "Reader not found" card; `Err 401` → `SessionExpired`. → **punch #2/#3** | ❌ |

#### Layer 11–13: Metrics / Perf / Cost
All **n/a** — US-10.5.2 §13–15: `profile_view` deferred to the SLO gate (never tag by handle); Neon reads only.

### Punch list
1. **Elm happy path** — new `frontend/tests/Page/ProfileTest.elm`: `init` yields `Loading` + `Api.getProfile`; `GotProfile (Ok profile)` → `Success`; the view renders `@handle` + one shelf link per `bookshelves` entry (to `Route.ProfileShelf`).
2. **Elm not-found (matrix)** — `GotProfile (Err <404>)` → `Failure` → the neutral "Reader not found" card (assert the ghost/blocked/unknown cases all land on the same card — no leak). Same file.
3. **Elm session-expiry** — `GotProfile (Err <401>)` → `SessionExpired` OutMsg (not `Failure`). Same file.
4. **Live-drive / E2E** — browser-drive `/u/:handle` as a second user and as unauthenticated: hub renders, shelf links present; a ghost handle → "Reader not found". Feeds the epic `e2e/tests/public-profile.spec.ts`.

**Visibility variations owned here:** the client-side face of the matrix — a viewer-visible
shelf renders a link; a ghost/blocked/unknown handle renders the identical "Reader not found"
card (no client-side leak). The *which shelves* filtering itself is the backend's (#213).

### Verdict
**RED — page built, 0 targeted tests.** The hub compiles and rides the green elm-test suite,
but has no `Page.Profile` state-machine coverage. 3 Elm punch items + 1 live-drive/E2E item.
These are missing-test-feature-exists, not feature gaps.

## Definition of Done
- [x] `Route.Profile`/`ProfileShelf`, `Page.Profile`, `Api.getProfile` + `PublicProfile` decoder, Main wiring.
- [x] `frontend/tests/Page/ProfileTest.elm` (happy + not-found + session-expiry) — 7 tests: identity render, meta (location+website), one browse link per visible shelf → `/u/:handle/:shelf`, empty-state copy, 404 → neutral "Reader not found" (no identity leak), 404 ≠ SessionExpired, 401 → SessionExpired.
- [ ] **Feature-Completeness Pre-Check ✅** — hub live-driven in the browser (epic-level E2E).
- [x] Punch items 1–3 closed (Elm happy / not-found matrix / session-expiry). Punch #4 (browser E2E) is the epic live-drive.
- [x] `Msg(..)` exposed for the test; `npx elm-test` green (804, 0 failures).
- [x] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️ (remaining item is the epic browser E2E).
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — pending the epic live-drive.

## Dependencies
#213 (`GET /api/u/:handle`). #215 will replace the temporary `ProfileShelf`→hub landing.

## Agent Assignment
elm-agent → testing-agent (E2E).

## Progress Notes
Landed on `feat/210-public-profiles`: `Page.Profile` hub, routes, `Api.getProfile`, Main wiring; `ProfileShelf` temporarily lands on the hub. Dedicated `ProfileTest.elm` + live-drive outstanding.
