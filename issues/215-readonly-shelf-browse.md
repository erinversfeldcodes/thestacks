# Issue #215: Read-only shelf browsing — `Page.Bookshelf` read-only + `Route.ProfileShelf`

## Summary
Render another reader's bookshelf at `/u/:handle/:bookshelf_name` as a **read-only** view:
add a `readOnly`/`editable` flag to `Page.Bookshelf`'s `Config`, parameterise the fetch URL to
`GET /api/u/:handle/bookshelves/:name` (#213's endpoint), and strip the edit / move / visibility /
remove controls and their mutating Msgs when read-only. Highest-churn frontend edit — split out
from #214 for that reason. **Not yet started** — `Route.ProfileShelf` currently lands on the
profile hub as a placeholder (`Main.elm:701`).

## User Stories
- **US-10.5.3** — Browse a Reader's Bookshelf (`docs/user_stories/US-10.5.3-browse-library.md`) — the Elm read-only render.

## Goal
Tapping a shelf on a profile hub renders that shelf's spines exactly as the viewer's
visibility permits (owner-only books absent, group books member-only, age-gated hidden from
unverified), with no mutating controls or requests.

## Scope Check
- >3 controllers? No (frontend; reuses #213's endpoint).
- >2 new endpoints? No (0).
- >~300 LOC? Borderline — `Page.Bookshelf` is the highest-churn module; if the read-only parameterisation exceeds ~300 LOC of change, split the config plumbing from the control-stripping. Flag at implementation.
- Combines unrelated concerns? No — all read-only-browse.

## Wiring
- [x] Router/SPA wiring included — `Route.ProfileShelf String String` (`Navigation/Route.elm:53,94`); Main must dispatch it to the read-only `Page.Bookshelf` (currently temporary → hub, `Main.elm:701-708`).
- [ ] Implementation only.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.5.3 — Browse a Reader's Bookshelf (Elm) | `Route.ProfileShelf handle name` (`Navigation/Route.elm:53`) → Main `ProfileShelf` (⬜ currently lands on the hub, `Main.elm:701`) → read-only `Page.Bookshelf` `Config` (⬜ `readOnly` flag not built, `Page/Bookshelf.elm`) → fetch `/api/u/:handle/bookshelves/:name` (#213 backend ✅ `profile_controller.ex:32`) | ⬜ to verify — read-only config + control-stripping not yet built; ProfileShelf is a placeholder | 🟡 | build the read-only `Page.Bookshelf` config + Main dispatch in this issue |

Verdict: 🟡 partial — the backend endpoint is built (#213); the Elm read-only render is the outstanding work. Build in-scope.

## Technical Requirements
- `Page.Bookshelf.Config` gains `readOnly : Bool` (or an `Editable`/`ReadOnly` variant) + a parameterised fetch URL (`/api/u/:handle/bookshelves/:name` when read-only, own-shelf URL otherwise).
- When read-only: omit the visibility control, move affordance, and remove/edit controls; drop their mutating Msgs so no mutation can be dispatched. An `owner`-only book of the target's is simply **absent** (not a faint spine — the faint-spine affordance is the owner's own view).
- Main dispatches `ProfileShelf handle name` to the read-only `Page.Bookshelf` (replace the temporary hub landing at `Main.elm:701`).

## Reviewer Context
- **Read-only means no mutating Msgs even exist** in the read-only path — not merely hidden buttons. A defence-in-depth check: the browse view must not be able to construct a move/visibility PUT.
- The backend already filters placements per-viewer (#213 `shelf_with_placements`), so the client renders whatever `count`/placements it receives — it must **not** re-filter or assume owner semantics.
- `Page.Bookshelf` is the unified module (Library/AntiLibrary/WishList) — config-driven; add the read-only mode as another config axis, not a fork.

## Test Audit
FULL 13-layer × US-10.5.3 (Elm read-only scope) — **baseline work-queue** (feature not built).
The backend matrix cells are #213's (with #213's own group/age-gate punch items); here the load
bearing layer is **Layer 10** plus the browse-surface matrix asserted via the backend endpoint
test and E2E.

**Framework-layer summary**

| Layer | 10.5.3 (browse) |
|-------|------------------|
| Elixir (backend endpoint) | ✅ core (#213 `profile_controller_test.exs:92/123/133`); group + age-gate = #213 punch |
| Elm read-only | ❌ not built |
| E2E | ❌ not built (dissolved from #218) |

#### Layer 1: API Calls
| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.3 | ❌ read-only `init` fetches `/api/u/:handle/bookshelves/:name` (assert the URL is the profile endpoint, not the own-shelf one). → **punch #1** | ❌ | ❌ (matrix) a 404 (hidden shelf / ghost / bad name) → "Reader not found"/empty state. → **punch #2** | ❌ |

#### Layer 2: Auth & Middleware Guards
| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.3 | ❌ signed-in vs anonymous fetch (viewer threads via `optional_auth`). → **punch #1** | ❌ | ❌ (SECURITY) **no mutating Msg constructible** in read-only mode (move/visibility/remove dropped). → **punch #3** | ❌ |

#### Layer 3: DB Interactions
| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.3 | ✅ backend `profile_controller_test.exs:92` platform placement shown, owner-only filtered (`count == 1`) | ✅ | ⚠️ (matrix) **group-member vs non-member** placement and **age-gate** rows are #213 punch items — assert them at the browse endpoint (member sees group placement; non-member does not; age-gated hidden from unverified). → **punch #4** | ⚠️ |

#### Layer 4–9: Events / Oban / External / Storage / Cache / dbt
All **n/a** — US-10.5.3 §6–11: read path; cover images are already-stored URLs served as-is; no events/jobs/cache/dbt.

#### Layer 10: Elm Frontend State Machine
| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.5.3 | ❌ read-only `Config`: spine grid renders the received placements; **no** visibility/move/remove controls in the view. → **punch #1/#3** | ❌ | ❌ 404 → not-available state; owner-only book of the target absent (not a faint spine). → **punch #2** | ❌ |

#### Layer 11–13: Metrics / Perf / Cost
All **n/a** — US §13–15: SLO gate; Neon reads only.

### Punch list
1. **Elm read-only fetch + render** — new `frontend/tests/Page/BookshelfReadOnlyTest.elm` (or extend `BookshelfTest.elm`): read-only `init` fetches `/api/u/:handle/bookshelves/:name`; spines render for the received placements.
2. **Elm not-available** — 404/hidden shelf → neutral not-available state; a target's owner-only book is absent (no faint spine). Same file.
3. **Elm no-mutation (SECURITY)** — assert the read-only view exposes no move/visibility/remove control and dispatches no mutating Msg.
4. **Backend browse matrix (group + age-gate)** — extend `apps/core/test/stacks_web/controllers/profile_controller_test.exs`: group placement shown to a member / hidden from a non-member; age-gated placement hidden from unauthenticated/unverified, shown to verified. (Shared with #213 punch — land whichever issue is picked up first.)
5. **E2E** — `e2e/tests/public-profile.spec.ts`: from a hub, tap a shelf → read-only spines; owner-only book absent; hidden shelf → not-available. Throwaway multi-user pattern from `privacy-block.spec.ts`.

**Visibility variations owned here:** the full placement matrix (platform / group-member /
group-non-member / unauthenticated) **plus** the orthogonal age-gate, observed on the browse
surface — asserted via punch #4 (backend) + punch #5 (E2E) + the Elm absence-of-owner-only render.

### Verdict
**RED — not built.** Backend endpoint exists and its core cell is green (#213); the read-only
Elm render, the no-mutation guarantee, and the group/age-gate browse-surface assertions are the
work queue. 5 punch items.

## Definition of Done
- [ ] `Page.Bookshelf` read-only `Config` + parameterised fetch URL + control/Msg stripping.
- [ ] Main dispatches `ProfileShelf` to the read-only view (replace the temporary hub landing).
- [ ] **Feature-Completeness Pre-Check ✅** — browse a second reader's shelf live: visible books only, no controls.
- [ ] Punch items 1–5 closed (incl. group + age-gate matrix + no-mutation).
- [ ] `npx elm-test` green; `just run just verify`.
- [ ] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`).

## Dependencies
#213 (`GET /api/u/:handle/bookshelves/:name`), #214 (hub links to `Route.ProfileShelf`).

## Agent Assignment
elm-agent (read-only config — highest-churn) → testing-agent (matrix + E2E).

## Progress Notes
Not started. `Route.ProfileShelf` present but temporarily routes to the profile hub (`Main.elm:701`).
