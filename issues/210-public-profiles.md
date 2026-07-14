# Issue #210: Public Profiles — the reader-facing half of visibility (EPIC)

## Summary
**Epic root.** The Stacks has a fully-built, well-tested visibility **enforcement**
layer (`Stacks.Visibility.resolve_visibility/2`, the owner/group/platform Audience
ladder, profile ceiling, block, age-gate, and the cross-user primitives
`viewable_shelves/2` + `shelf_with_placements/2`) — but **no reader-facing surface
that consumes it**. Setting a shelf to "platform" or "group" is meaningful at the API
yet invisible in the UX; there is no page to view another reader's profile or library.

This epic builds the consuming half — a public profile at `/u/:handle` with browsable,
visibility-gated shelves, plus the two discovery entry points (blog-author links and
people-search) — so bookshelf, placement, and profile visibility become observable and
testable end-to-end. It lands on branch `feat/210-public-profiles` and coordinates
focused child issues **#211–#217** in dependency order, opening a single PR when the
whole epic is complete.

Genuinely new scope: US-10.5.x did not exist before this epic; the enforcement layer
(ADR-006 `docs/decisions/006-rls-plus-application-visibility.md`, ADR-018
`docs/decisions/018-unified-audience-visibility-model.md`) needs **zero** changes —
only new reader surfaces.

## User Stories
This epic implements the four **US-10.5.x** reader-facing stories:
- **US-10.5.1** — Claim a Public Handle (`docs/user_stories/US-10.5.1-public-handle.md`) → #211, #212
- **US-10.5.2** — View a Reader's Public Profile (`docs/user_stories/US-10.5.2-view-profile.md`) → #213, #214
- **US-10.5.3** — Browse a Reader's Bookshelf (`docs/user_stories/US-10.5.3-browse-library.md`) → #213, #215
- **US-10.5.4** — Discover Readers (`docs/user_stories/US-10.5.4-discover-readers.md`) → #216, #217

## Goal
A reader can claim a memorable handle, another reader can open `/u/:handle`, see exactly
the bookshelves and books that user's visibility settings permit (owner-only hidden,
ghost → 404, group member-only, age-gated), and arrive there via a blog author's name or
a people-search — with cross-user leakage impossible at every surface.

## Child-issue decomposition (dependency order)

| # | Title | Depends on | Status |
|---|-------|-----------|--------|
| **#211** | User handles — schema + backfill + validation + auto-gen | — | ✅ DONE |
| **#212** | Set/change handle in Settings (backend + Elm input) | #211 | 🟡 backend DONE, Elm input PENDING |
| **#213** | Profile read endpoints (`GET /api/u/:handle`, `…/bookshelves/:name`) | #211 | ✅ DONE |
| **#214** | Frontend profile hub (`Page.Profile`, `Route.Profile`) | #213 | 🟡 hub DONE, dedicated Elm test PENDING |
| **#215** | Read-only shelf browsing (`Page.Bookshelf` read-only + `Route.ProfileShelf`) | #213, #214 | ⬜ PENDING |
| **#216** | Discovery — blog author → profile link (`author_handle`) | #211, #214 | ⬜ PENDING |
| **#217** | Discovery — people search (`Accounts.search_users/2` + UI) | #211, #214 | ⬜ PENDING |

**Note — no #218.** An earlier plan proposed a trailing `#218 E2E + test matrix` issue.
Per the completion-bar lesson (a green umbrella audit must not hide a deferred story),
that matrix is **dissolved into each child issue**: every issue carries its own
visibility-variation assertions in its Test Audit rather than deferring them to a
downstream "test everything" issue.

## Scope Check
<!-- This is an EPIC — the split has already happened; the Scope Check applies per child. -->
- More than 3 controllers / 2 endpoints / ~300 LOC? **Yes across the whole feature — which is exactly why it is decomposed.** Each child issue respects the ≤3-controller / ≤2-endpoint / ~300-LOC convention (#213 adds one controller + two `optional_auth` endpoints; the rest are single-surface).
- Combines unrelated concerns? No — all four stories share the reader-facing consumption of the one `Stacks.Visibility` model.

## Wiring
- [x] This epic is user-facing when complete (router + SPA routes wired across #213/#214/#215/#216/#217).
- [ ] Implementation only.

## Feature-Completeness Pre-Check
Roll-up of the child Pre-Checks (each child owns the authoritative row + file:line evidence).

| User Story | Built by | Live-drive | Verdict | Resolution |
|-----------|----------|-----------|---------|------------|
| US-10.5.1 — Claim a Public Handle | #211 (schema/validate/backfill/auto-gen) ✅; #212 (settings edit) 🟡 Elm input | ⬜ to verify (backend green; Elm handle field not yet built) | 🟡 | build the Elm handle input in #212 |
| US-10.5.2 — View a Reader's Profile | #213 (backend redacted surface) ✅; #214 (Elm hub) ✅ compiles + wired | ⬜ to verify | 🟡 | dedicated `ProfileTest.elm` + live-drive in #214 |
| US-10.5.3 — Browse a Reader's Bookshelf | #213 (`shelf` endpoint) ✅; #215 (read-only `Page.Bookshelf`) ⬜ | ⬜ to verify (ProfileShelf temporarily lands on the hub) | 🟡 | build read-only browse in #215 |
| US-10.5.4 — Discover Readers | #216 (author link) ⬜; #217 (people search) ⬜ | ⬜ to verify | ⬜ | build in #216 + #217 |

Verdict: 🟡 partial — the identity + profile-read half is built and tested; the browse
surface, discovery entry points, and the settings handle input are the remaining child work.

## Technical Requirements
See each child issue for its own Technical Requirements. Cross-cutting invariants:
- **Ghost/block gate is 404, never 403** — a ghost or blocked user is indistinguishable
  from a non-existent one (mirrors the block-404 rule), single-sourced through
  `Visibility.profile_visible?/2` (`apps/core/lib/stacks/visibility.ex:329`).
- **Redaction** — the public payload is `handle, display_name, website_url, city,
  country_code, bookshelves[].name` ONLY (`ProtoJSON.public_profile/2`,
  `apps/core/lib/stacks_web/proto_json.ex:577`) — never email/consent/role/prefs.
- **Search exclusion is enforced in SQL** (#217), never serializer redaction.
- **The resolver is not re-tested** — child tests assert each surface wires the correct
  `(viewer, target)` pair through; the combinatorics stay at the `visibility_test.exs` unit layer.

## Reviewer Context
- `/u/:handle` is an **Elm SPA route only** — the `/*path` catch-all serves the SPA; the API is `/api/u/:handle` (`apps/core/lib/core_web/router.ex:127-128`, `optional_auth` scope). No backend/SPA route collision.
- Handle edits reuse the **existing** `PUT /api/settings/profile` → `Accounts.update_profile/2`. No new mutation endpoint.
- Next free `User` proto field was 32 → `string handle = 32` (`mix proto.sync`-generated Ecto schema; do not hand-edit `apps/core/lib/stacks/gen/`).
- Handle is a **public identifier, not PII** — warehouse-safe (`stg_users.handle`), and must never travel alongside email/consent in a payload.

## Test Audit
This epic's audit is the **union of the child audits** — there is no separate umbrella
matrix (that is the point of dissolving #218). The epic is GREEN only when every child's
embedded 13-layer audit is GREEN.

| Child | Status | ❌ punch items remaining |
|-------|--------|--------------------------|
| #211 | ✅ DONE | 0 |
| #212 | 🟡 backend DONE, Elm PENDING | Elm handle input + its test; controller-level handle-in-response assertion |
| #213 | ✅ DONE (core matrix) | group-visible-shelf + age-gated variations not yet asserted |
| #214 | 🟡 hub DONE | dedicated `Page.Profile` Elm test; live-drive |
| #215 | ⬜ PENDING | entire read-only browse surface + placement/age-gate matrix + E2E |
| #216 | ⬜ PENDING | `author_handle` serializer + Elm link + tests |
| #217 | ⬜ PENDING | `search_users/2` SQL exclusion + endpoint + UI + privacy sad-path tests |

Verdict: **AMBER** — #211 GREEN; #213 GREEN on its core matrix with named punch items;
#212/#214 partial; #215/#216/#217 baseline work-queues. The epic is Done when all seven
child audits are GREEN.

## Definition of Done
- [ ] All child issues #211–#217 are individually Done (each Pre-Check ✅, each Test Audit GREEN).
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for all four US-10.5.x** — each happy
      path built end-to-end and observed on a live stack; no story reaches GREEN via `n/a (see #NNN)`.
- [ ] The full visibility matrix is observable end-to-end on a live stack: platform shelf
      shows, owner-only hidden, ghost → "Reader not found", group shelf member-only,
      age-gated hidden from unverified, blocked viewer → not found, search excludes ghosts/blocked.
- [ ] `mix proto.sync --check` green; `just run just verify` passes on the epic branch.
- [ ] Single epic PR opened from `feat/210-public-profiles`.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — all 7 items:
      every story driven live (local first); all applicable layers validated; no dangling
      P2/P3; logs clean; tracking regenerated to reality; live-driven locally before preview spend.

## Dependencies
Requires the built `Stacks.Visibility` enforcement layer (ADR-006, ADR-018), `Stacks.Social`
(blocking), and `Stacks.Shelving` cross-user accessors — all already present. No enforcement changes.

## Agent Assignment
Orchestrator (epic coordination) → elixir-agent (#211/#212/#213/#217 backend), elm-agent
(#212/#214/#215/#216 frontend), testing-agent (per-child audits + E2E).

## Progress Notes
- #211 landed: handle schema + backfill + validation + registration auto-gen (branch `feat/210-public-profiles`).
- #213 landed: `ProfileController` + `public_profile/2` + `profile_visible?/2` + routes.
- #214 landed: `Page.Profile` hub compiles, elm-test green, Main wiring; `ProfileShelf` temporarily lands on the hub pending #215.
- #212 backend landed (profile_changeset accepts handle, `/me` exposes handle); Elm handle input outstanding.
- #215/#216/#217 not yet started.
