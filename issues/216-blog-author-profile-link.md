# Issue #216: Discovery — blog author → profile link

## Summary
Turn a blog author's name into a discovery entry point: add `author_handle` to
`ProtoJSON.blog_post/1` (from the already-preloaded `post.user`) and render the author's
display name as a link to `Route.Profile author_handle` in the Elm blog views.
**Not yet started** — the serializer emits `author_display_name` but no `author_handle`, and
the Elm `BlogPost` type has no `authorHandle` field.

## User Stories
- **US-10.5.4** — Discover Readers (`docs/user_stories/US-10.5.4-discover-readers.md`) — the blog-author-link half.

## Goal
On `/blog/:id`, clicking the author's name navigates to `/u/:author_handle`; a ghost/blocked
author still lands on the US-10.5.2 gate → "Reader not found" (defence in depth — link discovery
never bypasses the profile gate).

## Scope Check
- >3 controllers? No (extends one serializer; no new endpoint).
- >2 new endpoints? No (0 — `GET /api/blog/posts/:id` gains a field).
- >~300 LOC? No.
- Combines unrelated concerns? No.

## Wiring
- [x] User-facing when complete (author link in blog views).
- [ ] Implementation only.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.5.4 — Discover Readers (blog author link) | Backend: `ProtoJSON.blog_post/1` (`apps/core/lib/stacks_web/proto_json.ex:367`) currently puts `:author_display_name` (:379) but ⬜ **no `:author_handle`**. Frontend: `Types.BlogPost` has `authorDisplayName` (`frontend/src/Types/BlogPost.elm:38`) but ⬜ **no `authorHandle`**; `Page/Blog/Post.elm` renders the name as plain text (⬜ not a link) | ⬜ to verify — serializer field + Elm field + link not built | 🟡 | build `author_handle` + Elm link in this issue |

Verdict: 🟡 partial — the profile target (#213/#214) exists; the blog→profile hop is unbuilt. Build in-scope.

## Technical Requirements
- `ProtoJSON.blog_post/1`: add `:author_handle` from `post.user.handle` (preloaded), mirroring `author_display_name/1`'s safe fallback (`nil` when the author association is not loaded).
- `Types.BlogPost`: add `authorHandle : Maybe String` (or `String`) + decoder field.
- `Page.Blog.Post` (and any list/index view rendering the author): render the display name as `a [ href (Route.toPath (Route.Profile handle)) ] [ text authorDisplayName ]` when a handle is present; plain text fallback otherwise.

## Reviewer Context
- The author is **already preloaded** (`author_display_name/1` reads `post.user`) — no new query; just expose the handle alongside.
- `author_handle` is a public identifier (not PII) — safe in the payload; do not gate it.
- Defence in depth: the link may point at a ghost/blocked author — that is fine, the profile gate (#213) returns 404 → "Reader not found". The link itself never leaks visibility.

## Test Audit
COMPACT — a serializer field + an Elm link; no US state machine beyond the anchor.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| API / serializer | yes | ❌ `blog_post/1` includes `author_handle` (present when author loaded; `nil`/absent when not). Suite: `apps/core/test/stacks_web/proto_json_test.exs` (alongside the existing `"handles nil author"` / `"handles not-loaded author"` cases at :86/:95). → **punch #1** |
| Elm view | yes | ❌ `Page.Blog.Post` renders the author name as a link to `Route.Profile handle` (and plain text when no handle). Suite: `frontend/tests/Page/Blog/…` (extend the existing blog-post test). → **punch #2** |
| Auth guards | yes | ✅ (by construction) author links are public (US §4); the target profile gate is #213's — no new guard here. |
| DB | no | n/a — author already preloaded; no new query. |
| Events | no | n/a — US §6. |
| Oban / external / storage / cache | no | n/a — US §7–10. |
| dbt | no | n/a — read path (US §11). |
| op metrics / perf / cost | no | n/a — US §13–15: SLO gate; Neon reads. |

**Visibility variations owned here:** the **defence-in-depth** case — an author link to a
ghost/blocked profile still resolves to "Reader not found" at the gate (asserted end-to-end via
E2E, since the gate itself is #213's). No visibility decision is made in the serializer/link.

### Punch list
1. **Serializer** — `proto_json_test.exs`: `blog_post/1` emits `author_handle` from a loaded author; nil/absent when the author is not loaded.
2. **Elm link** — blog-post test: the author name renders as an `a` with `href` = `Route.Profile authorHandle`; plain text when the handle is absent.
3. **E2E (defence in depth)** — clicking an author whose profile is a ghost lands on "Reader not found" (folds into the epic `public-profile.spec.ts`).

Verdict: **RED — not built.** 3 punch items (2 build+test, 1 E2E).

## Definition of Done
- [ ] `author_handle` on `ProtoJSON.blog_post/1`; `authorHandle` on `Types.BlogPost` + decoder.
- [ ] Blog views render the author as a link to `Route.Profile handle`.
- [ ] **Feature-Completeness Pre-Check ✅** — author link live-driven to a profile (and a ghost author → "Reader not found").
- [ ] Punch items 1–3 closed.
- [ ] `just run mix test` + `npx elm-test` green; `just run just verify`; `mix proto.sync --check` green (if the field rides a proto change) — otherwise plain `Map.put`.
- [ ] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`).

## Dependencies
#211 (handle), #214 (`Route.Profile` target).

## Agent Assignment
elixir-agent (serializer) + elm-agent (link).

## Progress Notes
Not started. `blog_post/1` emits `author_display_name` only; Elm `BlogPost` has no `authorHandle`.
