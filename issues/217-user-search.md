# Issue #217: Discovery — people search

## Summary
Let readers find each other by name: `Accounts.search_users/2` (a single SQL query filtered to
`profile_visibility = "platform"` + `display_name ILIKE` + block-exclusion in **both**
directions), a `GET /api/search/users` endpoint under `:optional_auth`, and a "Readers" section
on the search page linking each redacted `public_profile` result to `/u/:handle`.
**Not yet started** — no `search_users/2`, no endpoint, no people-search UI.

## User Stories
- **US-10.5.4** — Discover Readers (`docs/user_stories/US-10.5.4-discover-readers.md`) — the people-search half.

## Goal
Typing a name returns only **discoverable, non-blocked** readers — a ghost or a blocked user
**never** appears in the result set — each linking to their profile; no matches → empty state.

## Scope Check
- >3 controllers? No — extends/loads `SearchController` (one) with a users action, or a small dedicated endpoint.
- >2 new endpoints? No — one (`GET /api/search/users`).
- >~300 LOC? No.
- Combines unrelated concerns? No — all people-search.

## Wiring
- [x] Router/UI wiring included — new `GET /api/search/users` route + a "Readers" section on `Page.Search` (`frontend/src/Page/Search.elm`).
- [ ] Implementation only.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.5.4 — Discover Readers (people search) | ⬜ `Accounts.search_users/2` — not built (`apps/core/lib/stacks/accounts.ex` has no `search_users`); ⬜ `GET /api/search/users` — not routed (`core_web/router.ex:189` has `/search` for `SearchController.index` only); ⬜ Elm "Readers" section — not in `Page/Search.elm` | ⬜ to verify — none built | ⬜ | build query + endpoint + UI in this issue |

Verdict: ⬜ to verify — entirely unbuilt; the profile targets (#213/#214) exist. Build in-scope.

## Technical Requirements
- `Accounts.search_users(term, viewer)` — a **single** query: `WHERE profile_visibility = 'platform' AND display_name ILIKE '%term%'` AND the (viewer, candidate) pair is **not** blocked in either direction (anti-join / `NOT EXISTS` subquery on `op.user_blocks`). **No result may be filtered only in Elixir/serializer.**
- `GET /api/search/users?q=<term>` under `:optional_auth` (block-exclusion needs the viewer when signed in; unauthenticated omits only the block filter). Returns `[public_profile]` (redacted shape — handle + display_name + location).
- `Page.Search` gains a "Readers" section: query → `Api.searchUsers` → profile cards → links to `Route.Profile handle`.

## Reviewer Context
- **Exclusion is in SQL, never redaction** (the #217 top risk): a ghost (`profile_visibility = "owner"`) or a blocked user must never enter the result set. A serializer-only filter is a rejectable implementation.
- Block-exclusion is **bidirectional** — mirror `Social.blocked?/2` semantics (either direction hides the pair).
- `to_tsquery` chokes on multi-word strings — this search uses `ILIKE` (not full-text), so it is safe with multi-word terms; keep it `ILIKE` per the US.
- Search runs `:optional_auth`; when unauthenticated there is no viewer to block against, so only the `platform` filter applies (a ghost is still excluded).

## Test Audit
COMPACT — one query + one endpoint + a UI section; the **privacy sad paths are the point**.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB / query (happy) | yes | ❌ `search_users/2` returns platform, non-blocked readers matching `ILIKE`. Suite: `apps/core/test/stacks/accounts_test.exs`. → **punch #1** |
| DB / query (sad — SECURITY) | yes | ❌ **the matrix**: a ghost (`profile_visibility = "owner"`) is **never** returned; a blocked user (either direction) is **never** returned; a non-matching name is absent; assert exclusion happens in the query (result set), not post-filter. Suite: `accounts_test.exs`. → **punch #2** |
| API calls | yes | ❌ `GET /api/search/users?q=` → 200 `[public_profile]` (redacted, no email/consent/role); empty result on no match; excludes ghost/blocked end-to-end. Suite: new `apps/core/test/stacks_web/controllers/search_controller_test.exs` (or extend the search test). → **punch #3** |
| Auth guards | yes | ❌ `:optional_auth` — signed-in applies block-exclusion; unauthenticated still excludes ghosts. → **punch #3** |
| Elm state machine | yes | ❌ `Page.Search` "Readers" section: query → `Api.searchUsers` → `Loading`→`Success [cards]`; each card links to `Route.Profile handle`; empty state on no match. Suite: `frontend/tests/Page/SearchTest.elm` (extend). → **punch #4** |
| Events | no | n/a — US §6. |
| Oban / external / storage / cache | no | n/a — US §7–10. |
| dbt | no | n/a — read path (US §11). |
| op metrics | no | n/a — US §13: optional `user_search` count deferred to SLO gate; never tag by query. |
| perf | yes-ish | ⚠️ `display_name ILIKE` acceptable at current scale (US §14); note a trigram index as a future follow-up if search volume grows — not a test gap, a scaling note. |
| cost | no | n/a — Neon reads (US §15). |

**Visibility variations owned here (the whole matrix):** Discoverable+not-blocked → **yes**;
Ghost (`owner`) → **never**; blocked either direction → **never**; any tighter future tier →
**never** — each asserted at the **query** layer (punch #2) and re-proven end-to-end at the
endpoint (punch #3). Plus defence-in-depth: a result link to a since-turned-ghost profile still
hits the US-10.5.2 gate → 404.

### Punch list
1. **Query happy** — `accounts_test.exs`: `search_users/2` returns discoverable, non-blocked, ILIKE-matching readers.
2. **Query sad (SECURITY)** — `accounts_test.exs`: ghost excluded; blocked-either-direction excluded; exclusion is in the result set (not a serializer post-filter); no-match empty.
3. **Endpoint** — new `search_controller_test.exs`: 200 redacted `[public_profile]`; empty on no match; ghost/blocked excluded; `:optional_auth` signed-in vs anonymous.
4. **Elm** — `SearchTest.elm`: query → results → profile-card links to `/u/:handle`; empty state.

Verdict: **RED — not built.** 4 punch items; the 2 SQL-exclusion sad paths (ghost + blocked) are the load-bearing security asserts.

## Definition of Done
- [ ] `Accounts.search_users/2` (SQL-enforced platform-only + bidirectional block-exclusion).
- [ ] `GET /api/search/users` under `:optional_auth` returning redacted `public_profile`.
- [ ] `Page.Search` "Readers" section linking to `/u/:handle`.
- [ ] **Feature-Completeness Pre-Check ✅** — search live-driven: a discoverable reader appears; a ghost/blocked one never does.
- [ ] Punch items 1–4 closed.
- [ ] `just run mix test` + `npx elm-test` green; `just run just verify`.
- [ ] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`).

## Dependencies
#211 (handle), #213 (`public_profile` shape), #214 (`Route.Profile` target). `Social` blocking (pre-existing).

## Agent Assignment
elixir-agent (query + endpoint) + elm-agent (Readers section) → testing-agent (privacy sad paths + E2E).

## Progress Notes
Not started. No `search_users/2`, no `/api/search/users` route, no people-search UI.
