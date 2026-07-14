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

> **⚠️ Correction (Feature-Completeness Pre-Check, 2026-07-14).** This baseline audit's "Feature
> status" claim below is **partly wrong**: it states the block-user UI (modal + blocked-users list)
> and placement-visibility UI ship in `frontend/src/`. They **do not** — grep confirms no block/unblock
> or placement-visibility code or `Api` client exists. Those frontends are de-scoped to **#193** (block)
> and **#194** (placement). Punch items #9/#14 (block Elm+E2E) and #10/#16 (placement Elm+E2E) test UI
> that must be **built first** in those children. The §12 metrics counters are likewise unbuilt → **#197**.
> Also partial (small builds needed, folded into #196): shelf save-confirmation render (US-10.2.1),
> search-privacy info text (US-10.4.1), and the ViewAs banner label `"Not logged in"` (US-10.3.1).

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #122)

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
| Elixir      | ✅ | ✅ | ✅ (⚠️ ceiling-422) | ✅ | ✅ | ✅ | ✅ |
| Elm unit    | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | n/a |
| Elm program | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | n/a |
| Python      | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| E2E         | ⚠️ (API only) | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ |
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
| ✅ STRONG | **39** |
| ⚠️ shallow | **6** |
| ❌ missing | **12** |
| n/a (covered higher up / not applicable / by-design) | **125** |

182 cells total (13 layers × 7 US × happy/sad). E2E is tracked as a
cross-cutting framework-summary row + punch-list items, not counted in the
182-cell grid (consistent with the upload/marketplace audits). This is the
pre-implementation baseline; Issue #122's DoD requires regenerating to
0 ❌ / 0 ⚠️ after the punch list lands.

---

### Full audit tables

#### Layer 1: API Calls

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ user_settings_controller_test.exs — "returns 200 and sets profile_visibility to platform" + "…to owner" | ✅ | ✅ user_settings_controller_test.exs — "returns 422 when value is invalid", "returns 422 when parameter is missing" | ✅ |
| 10.1.2 | ✅ social_controller_test.exs — "returns 200 when block succeeds", "returns 200 when unblock succeeds", "returns list of blocked users" | ✅ | ✅ social_controller_test.exs — "returns 404 when target user does not exist", "returns 422 when trying to block self", "returns 422 on duplicate block", unblock "returns 404 when no block exists" | ✅ |
| 10.2.1 | ✅ bookshelf_controller_test.exs — "updates bookshelf visibility" (PUT /api/bookshelves/:id/visibility → 200 `{visibility: platform}`) | ✅ | ⚠️ bookshelf_controller_test.exs covers "returns 422 for invalid visibility value" + "returns 422 when visibility parameter is missing", but the Issue-§3 assertion "422 if shelf visibility **exceeds profile ceiling**" has no HTTP test (ceiling enforcement is verified only at the `validate_visibility_ceiling/3` unit level, never end-to-end through this endpoint) | ⚠️ |
| 10.2.2 | ✅ bookshelf_placement_controller_test.exs — "updates placement visibility within ceiling" (200) | ✅ | ✅ bookshelf_placement_controller_test.exs — "returns 422 when visibility exceeds bookshelf ceiling", "returns 422 when visibility parameter is missing" | ✅ |
| 10.2.3 | ✅ blog_controller_test.exs — "creates a draft post when authenticated" (201, visibility "owner"), "updates a post when called by the owner" | ✅ | ✅ blog_controller_test.exs — "returns 422 when visibility exceeds ceiling" (create + update), "returns 422 when required fields are missing" | ✅ |
| 10.3.1 | ⚠️ ViewAs is validated at the **plug** level (view_as_plug_test.exs — Phase 1 parse of `unauthenticated`/`platform`/`user:<uuid>`) and there is one content-endpoint halt test (bookshelf_controller_test.exs — "view_as halted"), but no positive content-endpoint integration test asserting that `GET …?view_as=unauthenticated` **actually filters** the returned payload to the simulated audience | ⚠️ | ✅ view_as_plug_test.exs — "user: (missing id) receives 422", "group:<id> receives 422 not_implemented", "unknown perspective receives 422" | ✅ |
| 10.4.1 | ✅ robots_test.exs — "file exists in priv/static", "disallows crawlers from …/u/ …/shelf/ …/post/ …/listing/", "contains a User-agent directive" | ✅ | ✅ (SECURITY) blog_controller_test.exs — "returns 404 for owner-only post viewed by non-owner"; visibility_test.exs — "unauthenticated viewer + private bookshelf → :hidden" (unauthenticated requests return no personal data) | ✅ |

#### Layer 2: Auth & Middleware Guards

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ user_settings_controller_test.exs — authenticated `auth_conn(user)` path drives the `:authenticated` pipeline | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated" | ✅ |
| 10.1.2 | ✅ social_controller_test.exs — authenticated block/unblock/list | ✅ | ⚠️ 401 fully covered (social_controller_test.exs — "returns 401 when not authenticated" ×3), but the Issue-§3/§4 `:rate_limit_social` guard (20/min per user on block/unblock) has **no test** — no "429"/"rate_limit" match in any social test | ⚠️ |
| 10.2.1 | ✅ bookshelf_controller_test.exs — owner path via `auth_conn` | ✅ | ✅ bookshelf_controller_test.exs — "returns 403 when user does not own the bookshelf", "returns 401 when not authenticated" | ✅ |
| 10.2.2 | ✅ bookshelf_placement_controller_test.exs — owner path | ✅ | ✅ (SECURITY) bookshelf_placement_controller_test.exs — "returns 403 when user does not own the placement", "returns 401 when not authenticated" | ✅ |
| 10.2.3 | ✅ blog_controller_test.exs — owner create/update | ✅ | ✅ (SECURITY) blog_controller_test.exs — "returns 403 when called by a non-owner" (update/delete/publish), "returns 401 when unauthenticated" | ✅ |
| 10.3.1 | ✅ view_as_plug_test.exs — Phase 2 "owner can use unauthenticated/platform/specific_user", "resource owner can use unauthenticated/platform on their own resource" | ✅ | ✅ (SECURITY) view_as_plug_test.exs — "resource owner cannot use specific_user — 403", "non-owner receives 403", "unauthenticated user receives 403" | ✅ |
| 10.4.1 | ✅ visibility_test.exs — unauthenticated viewer resolution (`current_resource == nil` → `:unauthenticated`) hides owner/group content | ✅ | ✅ (SECURITY) visibility_test.exs — "platform user viewer + profile_visibility owner (not owner) → :hidden"; settings.spec.ts — "settings endpoints return 401 when not authenticated" | ✅ |

#### Layer 3: Database Interactions

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ accounts_test.exs — "updates profile_visibility to platform"; recap batch UPDATE covered in Layer 5 | ✅ | ✅ accounts_test.exs — "returns changeset error for invalid visibility value" | ✅ |
| 10.1.2 | ⚠️ social_test.exs — "valid block → block row exists in DB", unblock "row removed", `blocked?`/`blocked_by?` bidirectional, `list_blocked_users` returns display_name + blocked_at. BUT the Issue-§4 assertions "paginated, 20 per page, ordered by `created_at desc`" are **not asserted** (only single-row lists tested; no >20 fixture, no ordering assertion) | ⚠️ | ✅ social_test.exs — "duplicate block → returns error (unique constraint)"; user_block_test.exs — "inserting a duplicate (same blocker + blocked) raises unique constraint error", "is invalid without blocker_id/blocked_id" | ✅ |
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
| 10.2.3 | ⚠️ blog_test.exs — "emits blog.post_created event on success", "emits blog.post_updated event on success" — BUT both assert `event_count` on `event_type` **only**; the Issue-§5 payload requirement `{user_id, title, visibility}` (visibility in payload) is never asserted | ⚠️ | n/a — ceiling/validation failures return `{:error, …}` before emit; no rollback-emit path | n/a |
| 10.3.1 | n/a — US §6: ViewAs emits no events | n/a | n/a — same | n/a |
| 10.4.1 | n/a — US §6: no events | n/a | n/a — same | n/a |

#### Layer 5: Background Jobs (Oban)

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 10.1.1 | ✅ visibility_recap_job_test.exs — "caps bookshelves stored as platform to owner", "caps placements stored as platform to owner", "returns :ok", payload count tests; accounts_test.exs — "enqueues VisibilityRecapJob after visibility change" | ✅ | ✅ visibility_recap_job_test.exs — "does not touch bookshelves already at owner", "does not touch another user's bookshelves" (cross-user isolation), "returns :ok with no DB changes when nothing to cap" (ceiling=platform early exit) | ✅ |
| 10.1.2 | n/a — block/unblock are synchronous (US §7) | n/a | n/a — same | n/a |
| 10.2.1 | n/a — cascading shelf caps are exercised through the recap job under US-10.1.1 (visibility_recap_job_test.exs bookshelf caps) | n/a | n/a — same | n/a |
| 10.2.2 | n/a — cascading placement caps exercised through the recap job under US-10.1.1 ("caps placements stored as platform to owner") | n/a | n/a — same | n/a |
| 10.2.3 | ⚠️ `tighten_posts_to_ceiling/2` itself is unit-tested (blog_test.exs), but the **recap-job → tighten path** and the `posts_capped` payload count are not asserted in visibility_recap_job_test.exs (only `bookshelves_capped` + `placements_capped` payload counts are verified) | ⚠️ | n/a — same tighten path | n/a |
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
| 10.1.1 | ❌ `Page.Settings.Privacy` exists (`frontend/src/Page/Settings/Privacy.elm`) but has **no test** — SettingsTest.elm covers only Consent + AgeVerification. `SetProfileVisibility` / `SaveProfileVisibility` / `SaveProfileVisibilityCompleted (Ok)` untested | ❌ | ❌ `SaveProfileVisibilityCompleted (Err)` → `savingProfile = Failure` ("Could not save…") untested | ❌ |
| 10.1.2 | ❌ Block confirmation modal (`UserClicksBlock → ConfirmBlock → PostBlock`) and blocked-users list rendering have no Elm test | ❌ | ❌ `GotBlockResponse (Err)` / already-blocked / not-found UI feedback untested | ❌ |
| 10.2.1 | ❌ `SetShelfVisibility shelfName value` / `SaveShelfVisibility` / `SaveShelfVisibilityCompleted (Ok)` in `Page.Settings.Privacy` untested | ❌ | ❌ `SaveShelfVisibilityCompleted (Err)` failure state untested | ❌ |
| 10.2.2 | ❌ placement-visibility UI (`UserSelectsPlacementVisibility → UpdatePlacementVisibility`, greyed-out ceiling options, faint-outline owner spine) untested | ❌ | ❌ ceiling-exceeded client-side disable + `GotUpdateResponse (Err)` untested | ❌ |
| 10.2.3 | ❌ `Page.Blog.Editor` exists (`frontend/src/Page/Blog/Editor.elm`) but has **no test** — `SetVisibility String` → Visibility parse, `SaveDraft`/`Publish` untested | ❌ | ❌ `SaveCompleted (Err)` / `PublishCompleted (Err)` failure feedback untested | ❌ |
| 10.3.1 | ❌ `Components.ViewAsBar` exists (`frontend/src/Components/ViewAsBar.elm`) but has **no test** — banner render when `view_as` present + `getViewAs` URL extraction untested | ❌ | ❌ `removeViewAs` URL rebuild (Exit preview) untested | ❌ |
| 10.4.1 | n/a — no Elm state machine (US §12); the "never appears in search results" line is static informational text with no interactive state | n/a | n/a — same | n/a |

#### Layer 11: Operational Metrics

All cells `n/a — covered by SLO gate`. `scripts/check-slo-gate.sh` scrapes
`/internal/metrics` post-deploy for per-route SLIs, and automatic Phoenix
endpoint + Oban telemetry cover event firing.

**Caveat (punch #20):** Issue #122 §12 enumerates ~10 visibility-specific
metrics (profile-visibility change counts by direction, recap outcome/cap
counts, block/unblock counts, block error rates, `:rate_limit_social` hits,
ViewAs usage/error counts by perspective, ceiling-rejection counts, crawler
+ robots.txt fetch counts). **None** of these is instrumented in
`visibility.ex` / `social.ex` / `view_as_plug.ex`, and no visibility mention
appears in any telemetry test (`observability_telemetry_test.exs` covers
vision/fuse/budget/costs only). Needs a decision: instrument + firing tests,
or descope §12 to the SLO gate.

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

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline). Items marked
**(SECURITY)** verify cross-user leakage / negative-access.

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

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 7-US matrix (182 cells):

- **39 ✅ STRONG** — the entire server-side visibility stack. Profile/shelf/
  placement/blog visibility endpoints, the 2-phase ViewAs plug, bidirectional
  blocking, the recap job (with cross-user isolation), robots.txt, and — most
  importantly — **cross-user leakage is genuinely well-covered**:
  `visibility_test.exs` (40 tests + 6 properties) asserts blocked→hidden,
  non-owner→hidden, unauthenticated→hidden, the marketplace exception, and
  group membership; controller tests assert non-owner 403/404 on every
  mutation and owner-only-post/owner-only-shelf leak-prevention on reads.
- **6 ⚠️ shallow** — HTTP-level shelf ceiling-violation 422 (#1), ViewAs
  content-endpoint filtering integration (#2), `:rate_limit_social` (#3),
  blocked-users pagination/ordering (#4), blog event **payload** visibility
  (#5), recap `posts_capped` path (#6).
- **12 ❌ missing** — **all at the Elm layer**: `Page.Settings.Privacy`,
  block modal + blocked list, shelf-visibility rows, placement visibility UI,
  `Page.Blog.Editor` visibility, and `Components.ViewAsBar` have **zero**
  tests despite all six modules existing in `frontend/src/`.
- **125 n/a** — external services, storage, cache, dbt (all seven US declare
  these N/A), operational/performance/cost metrics (SLO gate + no external
  spend), and the by-design event/job gaps (no events for individual shelf/
  placement changes; block/unblock synchronous).

**Headline findings:**
1. **Security enforcement is strong; UI verification is absent.** The
   highest-value sad path — cross-user leakage — is thoroughly tested at the
   Elixir context + controller + property layers (RLS + `resolve_visibility/2`
   per ADR-006). The risk is not in the enforcement but in the **complete
   absence of Elm and browser-level coverage** (12 ❌ + 7 E2E items): a UI
   regression that, e.g., renders a hidden placement or a broken ViewAs
   banner would not be caught by any current test.
2. **The frontend privacy surface is entirely untested.** Three shipped Elm
   modules (`Page.Settings.Privacy`, `Components.ViewAsBar`, `Page.Blog.Editor`)
   have no state-machine tests, and `e2e/tests/` has no `privacy.spec.ts` —
   only a single `PUT /api/settings/profile_visibility` API assertion in
   `settings.spec.ts`.
3. **Six enumerated Elixir gaps** are narrow but real: the shelf ceiling-422
   and rate-limit guards named in Issue #122 §2–§4 are unproven at the HTTP
   layer, blog events assert type-only (not visibility payload), and
   blocked-users pagination/ordering is unverified.

**Test runner totals at baseline (visibility-related, verified by grep/read):**
Elixir ~90 tests across 9 files (visibility_test 40 + property 6, social,
user_block, recap_job 11, accounts, blog, social_controller 13, view_as_plug
18, robots 6, bookshelf/placement/blog/user_settings controller subsets);
Elm **0** privacy tests; Playwright **2** profile-visibility assertions; dbt
0 (N/A). Punch list: **20 items**, of which #20 is partially blocked on
metrics instrumentation.
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`. *(Regenerated 2026-07-14 with file:line + local live-drive results; all 7 ✅.)*
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state. *(Pending — tracked in #207.)*
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`): stories driven live ✅ (38/39 local, the one cross-spec flake tracked in **#208**); every layer incl. events + metrics asserted ✅; no dangling P2/P3 (fixed or de-scoped to **#205**/#208) ✅; logs clean under the live drive ✅; tracking regenerated — Pre-Check ✅, 13-layer audit pending (**#207**); local live-drive before preview ✅.

## Dependencies
Requires Visibility module, Social context (blocking), ViewAs plug, VisibilityRecapJob, Blog context.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
