# Issue #122: E2E Test Suite — Privacy & Visibility

## Summary
**Epic root.** Comprehensive test + E2E coverage for the Privacy & Visibility system. Issue #122 is the epic root on integration branch `feat/122-e2e`; it coordinates focused child issues (#193–#200) and opens a single PR when the whole epic is complete.

A Feature-Completeness Pre-Check (2026-07-14) found that **two named stories' frontends were never built** despite this issue's original audit claiming they ship: **US-10.1.2 (Block a User) UI** and **US-10.2.2 (Override Placement Visibility) UI**. Per the de-scope rule, both are removed from this issue's claimed deliverable and built as child feature issues **#193** and **#194** within the epic. The §12 telemetry counters were also unbuilt → instrumented in **#197**.

Coverage for the built/partial stories — profile visibility ceiling (US-10.1.1), shelf visibility (US-10.2.1), blog post visibility (US-10.2.3), ViewAs preview (US-10.3.1), and search engine privacy (US-10.4.1) — plus the small partial-story builds and all E2E flows is delivered by children #195, #196, #198, #199, #200.

## User Stories
Claimed by this issue (built/partial surface): US-10.1.1 (Set Profile Visibility), US-10.2.1 (Set Shelf Visibility), US-10.2.3 (Set Blog Post Visibility), US-10.3.1 (Preview Content Visibility), US-10.4.1 (Search Engine Privacy).

**De-scoped to child feature issues** (frontends unbuilt — see Summary): US-10.1.2 (Block a User) → **#193**; US-10.2.2 (Override Placement Visibility) → **#194**. This issue no longer claims them.

## Goal
Validate the complete visibility system: profile ceiling enforcement with async recap, bidirectional blocking, shelf/placement/blog visibility overrides, marketplace exception for Looking for a Home, ViewAs preview for different audiences, and robots.txt/noindex guarantees.

## Scope Check
- Does this issue touch more than 3 controllers? Yes — but this is a test-only issue covering a unified visibility system.
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (all visibility-related, sharing the `Stacks.Visibility` module).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Feature-Completeness Pre-Check
<!--
Run the `feature-completeness` skill BEFORE writing any test suites for this issue. It proves each
named user story's happy path is actually BUILT end-to-end (and driven live), not merely that tests
are missing — the gate #124 lacked (US-14.3.2 was named, the audit went GREEN, yet the feature was
deferred to #173 → the #178/#179/#180/#182 cascade).

A 🟡 PARTIAL / ❌ MISSING verdict on a named story's happy path is a BLOCKING finding, NOT a
Test-Audit cell to reclassify `n/a (see #NNN)`. Resolve it exactly one of two ways: (a) build it
in-scope (add implementation phases; a design pass FIRST for non-trivial features), or (b) de-scope
it — delete the story from Summary + User Stories above and spin out a feature issue. Baseline =
"to verify"; fill verdicts + file:line evidence when this issue is picked up.
-->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.1.1 — Set Profile Visibility | route→`UserSettingsController.update_profile_visibility`→`Page.Settings.Privacy` dropdown+save | ✅ live (`privacy.spec.ts:42` Discoverable→Save→"Saved!") | ✅ | built (v1) |
| US-10.1.2 — Block a User | `SocialController.{block,unblock,blocked_users}` + **#193** `Components.BlockUserModal`+blocked-list; **#203** author name; **#206**/#122 group-feed affordance | ✅ live (`privacy-block.spec.ts:43` block→hide→unblock→restore) | ✅ | frontend built in #193 |
| US-10.2.1 — Set Shelf Visibility | **name-based** `PUT /bookshelves/:bookshelf_name/visibility`→`Shelving.set_bookshelf_visibility` (get-or-create + #195 ceiling) | ✅ live (`privacy.spec.ts:85` shelf save→"Visibility updated.") — **fixed a 400 name/id bug** | ✅ | bug fixed this pass |
| US-10.2.2 — Override Placement Visibility | **#194** dropdown+greying+faint-spine; **#201** `book_placement` serializer; shelf-spine `visibility` serialization (this pass) | ✅ live (`privacy-placement.spec.ts` 5/5 in isolation) — one cross-spec isolation flake tracked in **#208** | ✅ | built #194/#201 |
| US-10.2.3 — Set Blog Post Visibility | `BlogController.{create,update}`→`Page.Blog.Editor` dropdown | ✅ live (`privacy.spec.ts:125` visibility→Save Draft→Publish) | ✅ | built (v1) |
| US-10.3.1 — Preview Content Visibility | `ViewAsPlug` (2-phase) + `Components.ViewAsBar` (banner + exit) | ✅ live (`privacy.spec.ts:171` `?view_as=unauthenticated`→"Not logged in"→exit) | ✅ | built (v1) |
| US-10.4.1 — Search Engine Privacy | `robots.txt` + `noindex` meta + on-page info text (**#196**) | ✅ live (`privacy.spec.ts:201/210/229` robots + noindex + info text) | ✅ | built (v1) |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### 1. Playwright UI Tests
- **Profile visibility settings**: Navigate to `/settings/privacy` -> select "Only me" or "Discoverable" -> save -> "Saved!" confirmation
- **Shelf visibility rows**: Per-shelf dropdown (Only me / Group / Platform) with save button
- **Block user**: Click "Block [name]" from overflow menu -> confirmation modal -> content disappears
- **Unblock user**: Settings > Privacy > Blocked Users -> "Unblock" button -> content reappears
- **Blog post visibility**: Blog editor visibility dropdown (Only me / Group / Platform)
- **ViewAs preview**: Add `?view_as=unauthenticated` -> amber banner "Viewing as: Not logged in" -> "Exit preview" link
- **ViewAs exit**: Click "Exit preview" -> banner disappears, URL cleaned of `view_as` param
- **Hidden placement**: Owner sees faint outline spine for owner-only hidden books on visible shelf
- **Privacy informational text**: "Your profile and content will never appear in search engine results" on settings page

### 2. Playwright Navigation & Visual Tests
- **Auth guards**: All settings/privacy pages require auth
- **Ceiling violation feedback**: Attempt to set shelf visibility above profile ceiling -> error
- **Placement ceiling greyed options**: Options exceeding shelf ceiling are greyed out with tooltip

### 3. API Endpoint Tests
- `PUT /api/settings/profile_visibility` — 200 with `{ profile_visibility: "owner" }`, 422 on invalid value, 422 on missing param
- `POST /api/users/:id/block` — 200 `{ blocked: true }`, 422 `cannot_block_self`, 422 `already_blocked`, 404 `not_found`
- `DELETE /api/users/:id/block` — 200 `{ blocked: false }`, 404 `not_found`
- `GET /api/settings/blocked-users` — 200 with paginated list `{ blocked_users, total, page }`
- `POST /api/users/:id/block` — rate limited (`:rate_limit_social`, 20/min)
- Shelf visibility update — 200 on valid, 422 if exceeds profile ceiling
- Placement visibility update — 200 on valid, 422 if exceeds shelf ceiling
- Blog post create/update with visibility — 201/200 on valid, 422 `visibility_ceiling` if exceeds profile
- Blog `tighten_posts_to_ceiling/2` — batch update in transaction
- Content endpoints with `?view_as=unauthenticated` — filtered by simulated perspective
- `?view_as=platform` — content filtered as platform user
- `?view_as=user:<uuid>` — 403 for non-platform-owners
- `?view_as=group:<uuid>` — 422 not_implemented
- `?view_as=invalid` — 422 invalid_perspective
- Unauthenticated API requests to user-data endpoints — return no personal data
- `GET /robots.txt` — disallows crawlers from user content paths

### 4. Database Assertion Tests
- `op.users.profile_visibility` updated to "owner" or "platform"
- Visibility recap: `op.bookshelves.visibility` batch-updated to ceiling when profile tightens to "owner"
- Visibility recap: `op.bookshelf_placements.visibility` batch-updated through bookshelf join
- Visibility recap: `op.blog_posts` tightened via `Blog.tighten_posts_to_ceiling/2`
- `op.user_blocks` record created with `blocker_id`, `blocked_id`, `created_at`
- `op.user_blocks` unique constraint on `(blocker_id, blocked_id)`
- Block check: `Social.blocked?/2` bidirectional (either direction returns true)
- `Social.blocked_by?/2` one-directional check
- Blocked users list: paginated, 20 per page, ordered by `created_at desc`
- `op.bookshelves.visibility` updated with valid values (owner/group/platform)
- `Visibility.validate_visibility_ceiling/3` ranking: public(0) < platform(1) < owner(2)
- Marketplace exception: placement on `looking_for_home` with `listing_status: "active"` always visible
- `op.blog_posts.visibility` set on create, validated against profile ceiling

### 5. Event Flow Tests
- `user.profile_visibility_changed` emitted with `{ visibility }` payload
- `user.visibility_recap_completed` emitted by recap job with `{ new_visibility, bookshelves_capped, placements_capped, posts_capped }`
- `social.user_blocked` emitted with `{ blocked_id }`
- `social.user_unblocked` emitted with `{ blocked_id }`
- `blog.post_created` and `blog.post_updated` emitted with visibility in payload
- No events for shelf visibility changes or placement visibility changes (recap handles bulk)
- No events for ViewAs usage

### 6. Background Job Tests
- `VisibilityRecapJob` — queue `:default`, args `{ user_id, new_visibility }`, max_attempts 3
- Recap with ceiling "owner": violating values `["platform", "group"]` updated
- Recap with ceiling "platform": no violations, job exits early
- Recap batch-updates bookshelves, then placements (joined through bookshelves), then blog posts
- Recap emits `user.visibility_recap_completed` with counts

### 7. External Service Tests
- N/A

### 8. Storage Tests
- N/A

### 9. Cache Tests
- N/A

### 10. dbt Model Tests
- N/A for all visibility stories

### 11. Elm State Machine Tests
- `Page.Settings.Privacy` init: `profileVisibility = "owner"`, `shelfVisibilities` with 5 shelves
- `SetProfileVisibility` updates local value, resets save state
- `SaveProfileVisibility` -> `Api.updateProfileVisibility` -> `SaveProfileVisibilityCompleted`
- `SetShelfVisibility shelfName value` -> updates matching shelf
- `SaveShelfVisibility shelfName` -> API call -> `SaveShelfVisibilityCompleted`
- Block confirmation modal: `UserClicksBlock` -> `ConfirmBlock` -> API call
- `Components.ViewAsBar` renders amber banner when `view_as` present in URL
- `getViewAs` extracts `view_as` value from URL query
- `removeViewAs` rebuilds URL without `view_as` param
- Blog editor: `SetVisibility String` -> parses to Visibility type -> `SaveDraft`/`Publish`

### 12. Metrics & Telemetry Tests
- Profile visibility change counts by direction (tighten vs loosen)
- Recap job success/failure rates and cap counts
- Block/unblock event counts
- Block error rates (cannot_block_self, already_blocked)
- Rate limit hits on social endpoints
- ViewAs usage counts by perspective type
- ViewAs error rates (422, 403)
- Shelf/placement visibility change counts
- Ceiling violation rejection counts
- Crawler request counts, robots.txt fetch counts

## Reviewer Context
- `Visibility.resolve_visibility/2` enforces at read time regardless of stored values — the recap job brings stored state into sync.
- ViewAs has a two-phase design: Phase 1 (parse) in router pipeline, Phase 2 (authorize) in controller.
- Platform owners can use `{:specific_user, id}` perspective; regular users cannot.
- The marketplace exception means `looking_for_home` placements with active listings bypass visibility checks.

## Test Audit

> **✅ Regenerated to GREEN (2026-07-14).** The 2026-07-08 baseline below was pre-implementation
> (12 ❌ all-Elm + 6 ⚠️ Elixir + a 20-item punch list). The epic is now fully built and all 20
> punch items are RESOLVED with real, named tests: the block UI (#193 — `BlockUserModalTest.elm`,
> `PrivacyBlockedUsersTest.elm`, `privacy-block.spec.ts`), the placement-visibility UI (#194 —
> `BookDetailVisibilityTest.elm`, `privacy-placement.spec.ts`), the privacy/shelf/blog/ViewAs Elm
> surface (#196 — `SettingsPrivacyTest.elm`, `BlogEditorTest.elm`, `ViewAsBarTest.elm`), the browser
> flows (#198 — `privacy.spec.ts`), and the §12 visibility metrics (#206 — `visibility_telemetry_test.exs`).
> The six ⚠️ Elixir gaps (ceiling-422 HTTP, ViewAs payload-filter, `:rate_limit_social`, blocked-users
> pagination, blog-event payload, recap `posts_capped`) are closed. Every cell below is now ✅ or
> n/a-with-rationale.

_Test-coverage map for this issue (13 layers × user story, happy/sad columns). **Regenerated 2026-07-14 to the shipped state** — every `✅` cites a real test confirmed by grep/Read. The issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-14 (GREEN — all 20 punch items resolved). Prior baseline: 2026-07-08 (pre-implementation).

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
framework-wide mechanism test) and per-US repetition adds no guarantee.
Each `n/a` carries a one-line rationale.

**Scope note:** Issue #122 covers seven user stories under the unified
`Stacks.Visibility` system:
- **US-10.1.1** Set Profile Visibility (`docs/user_stories/US-10.1.1-profile-visibility.md`)
- **US-10.1.2** Block a User (`…/US-10.1.2-block-user.md`)
- **US-10.2.1** Set Bookshelf Visibility (`…/US-10.2.1-shelf-visibility.md`)
- **US-10.2.2** Override Placement Visibility (`…/US-10.2.2-placement-visibility.md`)
- **US-10.2.3** Set Blog Post Visibility (`…/US-10.2.3-blog-visibility.md`)
- **US-10.3.1** Preview Content Visibility / ViewAs (`…/US-10.3.1-preview-visibility.md`)
- **US-10.4.1** Search Engine Privacy (`…/US-10.4.1-search-engine-privacy.md`)

The matrix is 13 layers × 7 US, with happy/sad columns per cell. The
assertion inventory is drawn from each US's §1–§13 plus Issue #122's
per-category Technical Requirements.

**SECURITY framing (critical):** Visibility is enforced by RLS +
application-layer resolution (ADR-006, `docs/decisions/006-rls-plus-application-visibility.md`).
The highest-value sad path is **cross-user leakage** — can viewer A see
viewer B's private shelf / blocked content / owner-only post? Those cells
are flagged **(SECURITY)** below.

**Feature status:** the visibility system IS fully implemented server-side.
Verified surface:
- `Stacks.Visibility` (`apps/core/lib/stacks/visibility.ex`) — `resolve_visibility/2`,
  `can_view?/2`, `viewable_shelves/2`, `viewable_placements/2`,
  `validate_visibility_ceiling/3`, profile ceiling + block + age-gate +
  marketplace-exception + group-membership resolution.
- `Stacks.Social` (`apps/core/lib/stacks/social/social.ex`) — `block_user/2`,
  `unblock_user/2`, `blocked?/2`, `blocked_by?/2`, `list_blocked_users/2`.
- `Stacks.Workers.VisibilityRecapJob` (`apps/core/lib/stacks/workers/visibility_recap_job.ex`).
- `StacksWeb.Plugs.ViewAsPlug` (`apps/core/lib/stacks_web/plugs/view_as_plug.ex`) — 2-phase.
- Controllers: `UserSettingsController.update_profile_visibility`,
  `BookshelfController.update_visibility`, `BookshelfPlacementController.update_visibility`,
  `SocialController.{block,unblock,blocked_users}`, `BlogController.{create,update}`.
- Elm: `Page.Settings.Privacy`, `Components.ViewAsBar`, `Page.Blog.Editor`
  (all exist in `frontend/src/`).
- Static: `apps/core/priv/static/robots.txt` + `noindex` meta in `index.html`.

The audit therefore baselines real coverage, not "feature not implemented".
The dominant gap is at the **Elm and E2E layers** — the server-side
security enforcement is genuinely well-tested, but there is **zero**
frontend state-machine coverage and **near-zero** browser-flow coverage.

---

### Framework-layer summary

| Layer       | 10.1.1 | 10.1.2 | 10.2.1 | 10.2.2 | 10.2.3 | 10.3.1 | 10.4.1 |
|-------------|--------|--------|--------|--------|--------|--------|--------|
| Elixir      | ✅ | ✅ | ✅ (ceiling-422 now HTTP-tested) | ✅ | ✅ | ✅ | ✅ |
| Elm unit    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | n/a |
| Elm program | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | n/a |
| Python      | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| E2E         | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| dbt         | n/a | n/a | n/a | n/a | n/a | n/a | n/a |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks/visibility_test.exs` — 40 tests: profile ceiling, block check, age gate, **marketplace exception (4)**, ceiling validation, group visibility (7), resource edge cases, `can_view?`, `viewable_shelves`.
- `apps/core/test/stacks/visibility_property_test.exs` — 6 StreamData properties (owner-always-sees-own, owner-hidden-from-unauth, profile-ceiling, platform-visible, ceiling accept/reject).
- `apps/core/test/stacks/social_test.exs` — block/unblock/`blocked?`/`blocked_by?`/`list_blocked_users` (+ groups/grants).
- `apps/core/test/stacks/social/user_block_test.exs` — 4 changeset + unique-constraint tests.
- `apps/core/test/stacks/workers/visibility_recap_job_test.exs` — 11 tests (cap bookshelves/placements, payload counts, no-op paths, cross-user isolation).
- `apps/core/test/stacks/accounts_test.exs` — `update_profile_visibility/2`: event emit + `VisibilityRecapJob` enqueue + invalid changeset.
- `apps/core/test/stacks/blog_test.exs` — create/update/publish/delete + ceiling + `list_user_posts` visibility filter + `tighten_posts_to_ceiling/2` (transaction).
- `apps/core/test/stacks_web/social_controller_test.exs` — 13 endpoint tests (block/unblock/blocked-users incl. 401/404/422).
- `apps/core/test/stacks_web/plugs/view_as_plug_test.exs` — 18 tests (Phase 1 parse + Phase 2 authorize, all perspectives + 403/422).
- `apps/core/test/stacks_web/user_settings_controller_test.exs` — profile_visibility 200/422/422/401.
- `apps/core/test/stacks_web/bookshelf_controller_test.exs` — visibility update + read-time gates + view_as-halt.
- `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` — placement visibility 200/422-ceiling/403/404/422/401.
- `apps/core/test/stacks_web/controllers/blog_controller_test.exs` — blog visibility create/update/read (ceiling + non-owner 404/403).
- `apps/core/test/stacks_web/robots_test.exs` — 6 tests (robots.txt existence + disallow paths).
- `e2e/tests/settings.spec.ts` — `PUT /api/settings/profile_visibility` (200) + 401 guard.
- **No** Elm tests for `Page.Settings.Privacy`, `Components.ViewAsBar`, or `Page.Blog.Editor` (confirmed absent from `frontend/tests/`).

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **57** |
| ⚠️ shallow | **0** |
| ❌ missing | **0** |
| n/a (covered higher up / not applicable / by-design) | **125** |

182 cells total (13 layers × 7 US × happy/sad). E2E is tracked as a
cross-cutting framework-summary row + punch-list items, not counted in the
182-cell grid (consistent with the upload/marketplace audits). **GREEN**
(2026-07-14): the 12 ❌ (all Elm) + 6 ⚠️ (Elixir) baseline cells converted to
real ✅ coverage (39 → 57), and the 7 E2E framework-row items + §12 metrics all
landed — full citations in the regenerated tables + punch list below.

---

### Full audit tables

#### Layer 1: API Calls

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ user_settings_controller_test.exs — "returns 200 and sets profile_visibility to platform" + "…to owner" | ✅ | ✅ user_settings_controller_test.exs — "returns 422 when value is invalid", "returns 422 when parameter is missing" | ✅ |
| 10.1.2 | ✅ social_controller_test.exs — "returns 200 when block succeeds", "returns 200 when unblock succeeds", "returns list of blocked users" | ✅ | ✅ social_controller_test.exs — "returns 404 when target user does not exist", "returns 422 when trying to block self", "returns 422 on duplicate block", unblock "returns 404 when no block exists" | ✅ |
| 10.2.1 | ✅ bookshelf_controller_test.exs — "updates bookshelf visibility" (PUT /api/bookshelves/:bookshelf_name/visibility → 200) | ✅ | ✅ bookshelf_controller_test.exs — "returns 422 when the new visibility exceeds the profile ceiling (US-10.2.1)" (HTTP-level ceiling enforcement end-to-end through the endpoint), plus "returns 422 for invalid visibility value" + "…when visibility parameter is missing" | ✅ |
| 10.2.2 | ✅ bookshelf_placement_controller_test.exs — "updates placement visibility within ceiling" (200) | ✅ | ✅ bookshelf_placement_controller_test.exs — "returns 422 when visibility exceeds bookshelf ceiling", "returns 422 when visibility parameter is missing" | ✅ |
| 10.2.3 | ✅ blog_controller_test.exs — "creates a draft post when authenticated" (201, visibility "owner"), "updates a post when called by the owner" | ✅ | ✅ blog_controller_test.exs — "returns 422 when visibility exceeds ceiling" (create + update), "returns 422 when required fields are missing" | ✅ |
| 10.3.1 | ✅ bookshelf_controller_test.exs describe `GET /api/bookshelves/:bookshelf_name — view_as content filtering` → "owner viewing own bookshelf as unauthenticated sees only platform-visible placements" (positive payload-filter integration, not just the plug halt); view_as_plug_test.exs Phase-1 parse | ✅ | ✅ view_as_plug_test.exs — "user: (missing id) receives 422", "group:<id> receives 422 not_implemented", "unknown perspective receives 422" | ✅ |
| 10.4.1 | ✅ robots_test.exs — "file exists in priv/static", "disallows crawlers from …/u/ …/shelf/ …/post/ …/listing/", "contains a User-agent directive" | ✅ | ✅ (SECURITY) blog_controller_test.exs — "returns 404 for owner-only post viewed by non-owner"; visibility_test.exs — "unauthenticated viewer + private bookshelf → :hidden" (unauthenticated requests return no personal data) | ✅ |

#### Layer 2: Auth & Middleware Guards

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ user_settings_controller_test.exs — authenticated `auth_conn(user)` path drives the `:authenticated` pipeline | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated" | ✅ |
| 10.1.2 | ✅ social_controller_test.exs — authenticated block/unblock/list | ✅ | ✅ social_controller_test.exs — "returns 401 when not authenticated" ×3, and the `:rate_limit_social` guard (20/min per user) is now tested: describe `:rate_limit_social — per-user block/unblock throttle` → "returns 429 on the 21st block within the window" (`async: false`) | ✅ |
| 10.2.1 | ✅ bookshelf_controller_test.exs — owner path via `auth_conn` | ✅ | ✅ bookshelf_controller_test.exs — "returns 403 when user does not own the bookshelf", "returns 401 when not authenticated" | ✅ |
| 10.2.2 | ✅ bookshelf_placement_controller_test.exs — owner path | ✅ | ✅ (SECURITY) bookshelf_placement_controller_test.exs — "returns 403 when user does not own the placement", "returns 401 when not authenticated" | ✅ |
| 10.2.3 | ✅ blog_controller_test.exs — owner create/update | ✅ | ✅ (SECURITY) blog_controller_test.exs — "returns 403 when called by a non-owner" (update/delete/publish), "returns 401 when unauthenticated" | ✅ |
| 10.3.1 | ✅ view_as_plug_test.exs — Phase 2 "owner can use unauthenticated/platform/specific_user", "resource owner can use unauthenticated/platform on their own resource" | ✅ | ✅ (SECURITY) view_as_plug_test.exs — "resource owner cannot use specific_user — 403", "non-owner receives 403", "unauthenticated user receives 403" | ✅ |
| 10.4.1 | ✅ visibility_test.exs — unauthenticated viewer resolution (`current_resource == nil` → `:unauthenticated`) hides owner/group content | ✅ | ✅ (SECURITY) visibility_test.exs — "platform user viewer + profile_visibility owner (not owner) → :hidden"; settings.spec.ts — "settings endpoints return 401 when not authenticated" | ✅ |

#### Layer 3: Database Interactions

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ accounts_test.exs — "updates profile_visibility to platform"; recap batch UPDATE covered in Layer 5 | ✅ | ✅ accounts_test.exs — "returns changeset error for invalid visibility value" | ✅ |
| 10.1.2 | ✅ social_test.exs — block row exists, unblock removes it, `blocked?`/`blocked_by?` bidirectional; pagination + ordering now asserted (describe `list_blocked_users/2`): "paginates: >20 blocks returns 20 on page 1 with the correct total", "does not repeat entries across pages", "orders blocked users by created_at descending (most recent first)" | ✅ | ✅ social_test.exs — "duplicate block → returns error (unique constraint)"; user_block_test.exs — duplicate raises unique constraint, "is invalid without blocker_id/blocked_id" | ✅ |
| 10.2.1 | ✅ bookshelf_controller_test.exs update + visibility_test.exs — "viewable_shelves/2 returns only visible bookshelves for platform user", "owner sees all their own bookshelves" | ✅ | ✅ bookshelf_controller_test.exs — "returns 422 for invalid visibility value" (changeset inclusion) | ✅ |
| 10.2.2 | ✅ bookshelf_placement_controller_test.exs update; visibility_test.exs — placement group-visibility resolution | ✅ | ✅ bookshelf_placement_controller_test.exs — "returns 422 when visibility exceeds bookshelf ceiling" | ✅ |
| 10.2.3 | ✅ blog_test.exs — "creates a post with valid attrs", "defaults to draft (visibility: owner)", "list_user_posts owner sees all incl. drafts", "non-owner sees only published", `tighten_posts_to_ceiling/2` "runs in a transaction (all or nothing)" | ✅ | ✅ (SECURITY) blog_test.exs — "non-owner cannot see owner-only posts even if published", "enforces visibility ceiling — rejects less restrictive than profile", "returns changeset error when required fields missing" | ✅ |
| 10.3.1 | n/a — ViewAs performs no DB writes (US §5); it only changes the viewer context passed to existing read queries | n/a | n/a — same | n/a |
| 10.4.1 | n/a — enforced at middleware/template level, not via DB (US §5) | n/a | n/a — same | n/a |

#### Layer 4: Event Flow & Lifecycle

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ accounts_test.exs — "emits user.profile_visibility_changed event"; visibility_recap_job_test.exs — "emits user.visibility_recap_completed event" + "event payload includes correct bookshelves_capped count" + "…placements_capped count" | ✅ | ✅ visibility_recap_job_test.exs — "does not emit event when ceiling is platform and nothing is capped" (negative-emission) | ✅ |
| 10.1.2 | ✅ social_test.exs — "block_user/2 emits social.user_blocked event", "unblock_user/2 emits social.user_unblocked event" (payload `{blocked_id}`) | ✅ | n/a — a failed block short-circuits (self / not_found / already_blocked) **before** the insert+emit, so there is no rollback-emit path to negatively assert | n/a |
| 10.2.1 | n/a — US §6: no events emitted for individual shelf visibility changes (recap handles bulk) | n/a | n/a — same | n/a |
| 10.2.2 | n/a — US §6: no events for individual placement visibility changes | n/a | n/a — same | n/a |
| 10.2.3 | ✅ blog_test.exs — "blog.post_created event payload includes user_id, title, and visibility", "blog.post_updated event payload includes user_id, title, and visibility" (payload asserted, not just event_type) | ✅ | n/a — ceiling/validation failures return `{:error, …}` before emit; no rollback-emit path | n/a |
| 10.3.1 | n/a — US §6: ViewAs emits no events | n/a | n/a — same | n/a |
| 10.4.1 | n/a — US §6: no events | n/a | n/a — same | n/a |

#### Layer 5: Background Jobs (Oban)

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ visibility_recap_job_test.exs — "caps bookshelves stored as platform to owner", "caps placements stored as platform to owner", "returns :ok", payload count tests; accounts_test.exs — "enqueues VisibilityRecapJob after visibility change" | ✅ | ✅ visibility_recap_job_test.exs — "does not touch bookshelves already at owner", "does not touch another user's bookshelves" (cross-user isolation), "returns :ok with no DB changes when nothing to cap" (ceiling=platform early exit) | ✅ |
| 10.1.2 | n/a — block/unblock are synchronous (US §7) | n/a | n/a — same | n/a |
| 10.2.1 | n/a — cascading shelf caps are exercised through the recap job under US-10.1.1 (visibility_recap_job_test.exs bookshelf caps) | n/a | n/a — same | n/a |
| 10.2.2 | n/a — cascading placement caps exercised through the recap job under US-10.1.1 ("caps placements stored as platform to owner") | n/a | n/a — same | n/a |
| 10.2.3 | ✅ visibility_recap_job_test.exs describe `perform/1 — posts capped via tighten_posts_to_ceiling`: "caps posts more visible than the ceiling and reports posts_capped in payload", "reports posts_capped: 0 when no posts violate the ceiling" | ✅ | n/a — same tighten path | n/a |
| 10.3.1 | n/a — no jobs (US §7) | n/a | n/a — same | n/a |
| 10.4.1 | n/a — no jobs (US §7) | n/a | n/a — same | n/a |

#### Layer 6: External Service Calls

| US | Happy Path | Sad Path |
|----|------------|----------|
| all | n/a — visibility, blocking, ViewAs, and search-privacy make no external service calls (every US §8 = N/A) | n/a — same |

#### Layer 7: Storage (R2 / Local)

| US | Happy Path | Sad Path |
|----|------------|----------|
| all | n/a — no storage in any visibility story (every US §9 = N/A) | n/a — same |

#### Layer 8: Cache Interactions

| US | Happy Path | Sad Path |
|----|------------|----------|
| all | n/a — block checks and visibility resolution are direct DB queries; no cache layer in the read/write path (every US §10 = N/A) | n/a — same |

#### Layer 9: dbt Model Dependencies

| US | Happy Path | Sad Path |
|----|------------|----------|
| all | n/a — every visibility US §11 = N/A. (Blog `blog.post_updated` → `DbtRefreshHandler` refresh is a downstream mechanism tested under the blog issue, not a visibility assertion.) | n/a — same |

#### Layer 10: Elm Frontend State Machine

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ `SettingsPrivacyTest.elm` describe "profile visibility (US-10.1.1)" — "SetProfileVisibility updates the local value", "SaveProfileVisibility with a token sets savingProfile to Loading", "SaveProfileVisibilityCompleted Ok sets savingProfile to Success" | ✅ | ✅ `SettingsPrivacyTest.elm` — "SaveProfileVisibilityCompleted Err sets savingProfile to Failure" | ✅ |
| 10.1.2 | ✅ `BlockUserModalTest.elm` — "BlockRequested opens the confirmation modal and closes the menu", "BlockConfirmed with a token sets status to Loading", "BlockCompleted Ok marks Success and emits UserBlocked with the id"; `PrivacyBlockedUsersTest.elm` — "view lists each blocked reader with an Unblock button", "GotUnblockResponse Ok removes the reader from the list" | ✅ | ✅ `BlockUserModalTest.elm` — "BlockCompleted already_blocked shows a distinct message and stays local", "BlockCompleted not_found shows a distinct message", "BlockCompleted 401 escalates to SessionExpired"; `PrivacyBlockedUsersTest.elm` — "GotUnblockResponse not_found…keeps the row", "GotUnblockResponse non-401 failure surfaces an error" | ✅ |
| 10.2.1 | ✅ `SettingsPrivacyTest.elm` describe "shelf visibility (US-10.2.1)" — "SetShelfVisibility updates only the matching shelf", "SaveShelfVisibility with a token sets savingShelf to Loading", "SaveShelfVisibilityCompleted Ok sets savingShelf to Success" | ✅ | ✅ `SettingsPrivacyTest.elm` — "SaveShelfVisibilityCompleted Err sets savingShelf to Failure" | ✅ |
| 10.2.2 | ✅ `BookDetailVisibilityTest.elm` — "ceiling_greying: an option more permissive than the shelf ceiling is disabled", "select_saves: choosing an allowed visibility PUTs and records success", "helper_text: a restricting shelf ceiling shows always-visible helper text" (faint owner-only spine covered at E2E, punch #16) | ✅ | ✅ `BookDetailVisibilityTest.elm` — "server_error: a 422 ceiling rejection surfaces a warm failure message", "rollback: a failed save reverts the select to the prior visibility" | ✅ |
| 10.2.3 | ✅ `BlogEditorTest.elm` describe "Page.Blog.Editor (US-10.2.3)" — "\"owner\" parses to Owner", "\"platform\" parses to Platform", "unknown value falls back to Owner", "SaveCompleted Ok sets saving to Success", "PublishCompleted Ok sets publishing to Success" | ✅ | ✅ `BlogEditorTest.elm` — "SaveCompleted Err sets saving to Failure", "PublishCompleted Err sets publishing to Failure" | ✅ |
| 10.3.1 | ✅ `ViewAsBarTest.elm` — "renders the bar when view_as is present", "renders an Exit preview link when view_as is present", "getViewAs extracts the view_as value from the query" | ✅ | ✅ `ViewAsBarTest.elm` — "removeViewAs drops the view_as param and keeps the path", "unauthenticated perspective renders the 'Not logged in' label" | ✅ |
| 10.4.1 | n/a — no Elm state machine (US §12); the "never appears in search results" line is static informational text with no interactive state | n/a | n/a — same | n/a |

#### Layer 11: Operational Metrics

All cells `n/a — covered by SLO gate`. `scripts/check-slo-gate.sh` scrapes
`/internal/metrics` post-deploy for per-route SLIs, and automatic Phoenix
endpoint + Oban telemetry cover event firing.

**Resolved (punch #20, via #206):** Issue #122 §12's visibility metrics are now
instrumented AND firing-tested in `apps/core/test/stacks/visibility_telemetry_test.exs`:
profile-visibility change direction (`visibility.ex:365 emit_profile_visibility_change/2`
— tighten/loosen), `ceiling_rejection` (`visibility.ex:388`, whitelisted
`:post`/`:placement`/`:bookshelf`), recap outcome + cap counts (`:capped`/`:noop`),
block/unblock + block_error by reason (`social.ex` + `social_controller.ex`),
`:rate_limit` tagged `:social` (`core_web/telemetry.ex`), ViewAs usage/error by
perspective (`view_as_plug.ex:131/135`, uuid never leaked), and crawler `robots_fetch`.
So the Layer-11 cells are covered by real firing tests rather than deferred to the SLO gate.

#### Layer 12: Performance & Usability Metrics

All cells `n/a — covered by SLO gate, not unit tests`. Recap job duration,
visibility-resolution latency, and save latencies (US §14 targets) are
in-test SLA bounds that are an anti-pattern under variable CI timing.

#### Layer 13: Cost Tracking

All cells `n/a — no external API spend`. Every visibility US §15 states the
only cost is Neon compute for DB reads/writes (recap batch UPDATEs being the
heaviest path); there is no per-call spend to record in `BudgetTracker`, and
Fly/Neon compute is covered by the cost dashboard at deploy time.

---

### Punch list (all 20 RESOLVED — 2026-07-14)

Every ❌/⚠️ cell from the 2026-07-08 baseline, now resolved with a real named
test (cited in the regenerated cells above; verified by grep/Read). Items marked
**(SECURITY)** verify cross-user leakage / negative-access. The "Where it belongs"
column records where each landed — every row is ✅ DONE.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 10.2.1 sad **(SECURITY)** | HTTP-level 422 when a shelf visibility update **exceeds the profile ceiling** (set profile "owner", attempt `PUT /api/bookshelves/:id/visibility {visibility: platform}` → 422) — currently only unit-level `validate_visibility_ceiling/3` | `apps/core/test/stacks_web/bookshelf_controller_test.exs` |
| 2 | L1 10.3.1 happy | Content-endpoint integration: owner appends `?view_as=unauthenticated` to a real content GET and the returned payload is filtered as an unauthenticated audience would see it (not just the plug halt) | `apps/core/test/stacks_web/bookshelf_controller_test.exs` |
| 3 | L2 10.1.2 sad | `:rate_limit_social` (20/min) test: 21st block/unblock within a window returns 429 | `apps/core/test/stacks_web/social_controller_test.exs` |
| 4 | L3 10.1.2 happy | `list_blocked_users/2` pagination (insert >20 blocks → page 1 returns 20, page 2 the rest, `total` correct) + ordering `created_at desc` | `apps/core/test/stacks/social_test.exs` |
| 5 | L4 10.2.3 happy | Extend the two "emits blog.post_*" tests to assert payload `{user_id, title, visibility}` — not just `event_type` count | `apps/core/test/stacks/blog_test.exs` |
| 6 | L5 10.2.3 happy | Recap → `tighten_posts_to_ceiling` path: recap job with violating posts caps them AND the `user.visibility_recap_completed` payload `posts_capped` count is asserted | `apps/core/test/stacks/workers/visibility_recap_job_test.exs` |
| 7 | L10 10.1.1 happy+sad | Elm `Page.Settings.Privacy`: init (`profileVisibility="owner"`, 5 shelf rows), `SetProfileVisibility` updates + resets save state, `SaveProfileVisibility` → Loading + `Api.updateProfileVisibility`, `SaveProfileVisibilityCompleted (Ok)`→Success / `(Err)`→Failure | new `frontend/tests/Page/SettingsPrivacyTest.elm` |
| 8 | L10 10.2.1 happy+sad | Elm `Page.Settings.Privacy` shelf rows: `SetShelfVisibility shelfName value` updates the matching row, `SaveShelfVisibility` → Loading + `Api.updateShelfVisibility`, `SaveShelfVisibilityCompleted (Ok/Err)` | same file as #7 |
| 9 | L10 10.1.2 happy+sad **(SECURITY)** | Elm block flow: `UserClicksBlock → ConfirmBlock` modal, `PostBlock` cmd, `GotBlockResponse (Ok)` hides content / `(Err)` (already_blocked, not_found) feedback; blocked-users list render + Unblock | new `frontend/tests/…` (block modal + Privacy blocked-users list) |
| 10 | L10 10.2.2 happy+sad **(SECURITY)** | Elm placement visibility: `UserSelectsPlacementVisibility → UpdatePlacementVisibility`, client-side greying of options above shelf ceiling, faint-outline owner-only spine, `GotUpdateResponse (Err)` | new `frontend/tests/Page/…` (bookshelf/detail overlay) |
| 11 | L10 10.2.3 happy+sad | Elm `Page.Blog.Editor`: `SetVisibility String` parses to `Owner`/`Group`/`Platform`, `SaveDraft`/`Publish` fire correct cmds, `SaveCompleted`/`PublishCompleted (Ok/Err)` | new `frontend/tests/Page/BlogEditorTest.elm` |
| 12 | L10 10.3.1 happy+sad | Elm `Components.ViewAsBar`: banner renders only when `view_as` present, `getViewAs` extracts value, `removeViewAs` rebuilds URL without the param (Exit preview) | new `frontend/tests/ViewAsBarTest.elm` |
| 13 | E2E 10.1.1 | Playwright privacy UI flow: `/settings/privacy` → select "Only me"/"Discoverable" → "Save Profile Visibility" → "Saved!" confirmation; auth guard on the page | `e2e/tests/privacy.spec.ts` (new) or extend `settings.spec.ts` |
| 14 | E2E 10.1.2 **(SECURITY)** | Playwright: "Block [name]" from overflow → confirmation modal → content disappears; Settings › Blocked Users → "Unblock" → content reappears | `e2e/tests/privacy.spec.ts` |
| 15 | E2E 10.2.1 | Playwright shelf-visibility rows: per-shelf dropdown (Only me/Group/Platform) + Save → "Saved!"; ceiling-violation feedback when above profile ceiling | `e2e/tests/privacy.spec.ts` |
| 16 | E2E 10.2.2 | Playwright: owner sees faint-outline spine for owner-only hidden book on a visible shelf; placement ceiling options greyed with tooltip | `e2e/tests/privacy.spec.ts` |
| 17 | E2E 10.2.3 | Playwright blog editor visibility dropdown (Only me/Group/Platform) → Save Draft/Publish | `e2e/tests/privacy.spec.ts` or `blog.spec.ts` |
| 18 | E2E 10.3.1 | Playwright ViewAs: append `?view_as=unauthenticated` → amber banner "Viewing as: Not logged in" → "Exit preview" removes the param | `e2e/tests/privacy.spec.ts` |
| 19 | E2E 10.4.1 | Playwright: `GET /robots.txt` disallows user-content paths, `<meta name="robots" content="noindex, nofollow">` present in SPA shell, privacy informational text on settings page. (Elixir robots_test.exs covers robots.txt server-side but there is no browser-level noindex/informational-text assertion.) | `e2e/tests/privacy.spec.ts` or `security-headers.spec.ts` |
| 20 | L11 all US | Decide + implement: instrument the Issue-§12 visibility metrics (profile-visibility change direction, recap outcomes/cap counts, block/unblock counts + error rates, `:rate_limit_social` hits, ViewAs usage/error by perspective, ceiling-rejection counts, crawler/robots.txt fetch counts) with telemetry firing tests, **or** formally descope §12 to the SLO gate and reclassify. **Partially blocked on instrumentation** — the counters do not exist yet. | `apps/core/lib/stacks/{visibility,social}.ex` + `view_as_plug.ex` + new telemetry test |

---

### Verdict

**GREEN — audit resolved (2026-07-14).** State across the
13-layer × 7-US matrix (182 cells):

- **57 ✅ STRONG** — the entire server-side visibility stack PLUS the full Elm +
  E2E surface. Cross-user leakage remains the anchor: `visibility_test.exs`
  (40 tests + 6 properties) asserts blocked→hidden, non-owner→hidden,
  unauthenticated→hidden, the marketplace exception, and group membership;
  controller tests assert non-owner 403/404 on every mutation. The 2026-07-14
  regeneration added the 6 Elixir gap-fills (ceiling-422 HTTP, ViewAs
  payload-filter, `:rate_limit_social` 429, blocked-users pagination/order,
  blog-event payload, recap `posts_capped`) plus the full Elm layer
  (`SettingsPrivacyTest`, `BlockUserModalTest`+`PrivacyBlockedUsersTest`,
  `BookDetailVisibilityTest`, `BlogEditorTest`, `ViewAsBarTest`) and E2E flows.
- **0 ⚠️ / 0 ❌** — the DoD bar is met; all 20 punch items resolved with real
  named tests, §12 metrics fire in `visibility_telemetry_test.exs`.
- **125 n/a** — external services, storage, cache, dbt (all seven US declare
  these N/A), operational/performance/cost metrics (SLO gate + no external
  spend), and the by-design event/job gaps (no events for individual shelf/
  placement changes; block/unblock synchronous).

**Headline findings (resolved 2026-07-14):**
1. **Security enforcement strong AND UI now verified.** Cross-user leakage is
   thoroughly tested at the Elixir context + controller + property layers (RLS +
   `resolve_visibility/2` per ADR-006); the Elm + browser layers that were absent
   at baseline are now covered — a regression rendering a hidden placement or a
   broken ViewAs banner is caught by `BookDetailVisibilityTest`, `ViewAsBarTest`,
   and the `privacy*.spec.ts` browser flows.
2. **The frontend privacy surface is fully tested.** `Page.Settings.Privacy`
   (`SettingsPrivacyTest`), `Components.ViewAsBar` (`ViewAsBarTest`),
   `Page.Blog.Editor` (`BlogEditorTest`), the block flow (`BlockUserModalTest` +
   `PrivacyBlockedUsersTest`), and placement visibility (`BookDetailVisibilityTest`)
   all have state-machine tests, backed by `privacy.spec` / `privacy-block.spec` /
   `privacy-placement.spec` browser coverage.
3. **The six Elixir gaps are closed:** shelf ceiling-422 + `:rate_limit_social`
   429 proven at the HTTP layer, blog events assert the `{user_id, title,
   visibility}` payload, blocked-users pagination/ordering asserted, ViewAs
   payload-filter integration, and the recap `posts_capped` path.

**Test runner totals (visibility-related, verified by grep/read, 2026-07-14):**
Elixir (visibility_test 40 + property 6, visibility_telemetry, social,
user_block, recap_job incl. `posts_capped`, accounts, blog incl. event payload,
social_controller incl. `:rate_limit_social` 429, view_as_plug 18, robots,
bookshelf/placement/blog/user_settings controller incl. ceiling-422 + view_as
payload filter); Elm privacy tests across `SettingsPrivacyTest`,
`BlockUserModalTest`, `PrivacyBlockedUsersTest`, `BookDetailVisibilityTest`,
`BlogEditorTest`, `ViewAsBarTest`; Playwright `privacy.spec`, `privacy-block.spec`,
`privacy-placement.spec`; dbt N/A. Punch list: **20 items — all resolved**.
## Definition of Done
- [x] All 11 test categories implemented with specific test cases listed above
- [x] Tests pass with `TEST_TARGET=local`
- [x] No flaky tests (the cross-spec flake was resolved by the #208 throwaway-user isolation — 39/39 local)
- [x] `just verify` passes
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`. *(Regenerated 2026-07-14 with file:line + local live-drive results; all 7 ✅.)*
- [x] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️`. Regenerated 2026-07-14: all 20 punch items resolved with real named tests (39 → 57 ✅).
- [x] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`): stories driven live ✅ (39/39 local); every layer incl. events + metrics asserted ✅ (§12 metrics fire in `visibility_telemetry_test.exs`); no dangling P2/P3 (fixed or de-scoped to **#205**) ✅; logs clean under the live drive ✅; tracking regenerated — Pre-Check ✅ + 13-layer audit ✅; local live-drive done, preview gate deferred to post-#209 (single merge).

## Dependencies
Requires Visibility module, Social context (blocking), ViewAs plug, VisibilityRecapJob, Blog context.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
