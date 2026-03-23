# Issue #122: E2E Test Suite — Privacy & Visibility

## Summary
Comprehensive E2E test coverage for profile visibility ceiling (US-10.1.1), user blocking (US-10.1.2), shelf visibility (US-10.2.1), placement visibility with marketplace exception (US-10.2.2), blog post visibility (US-10.2.3), ViewAs preview (US-10.3.1), and search engine privacy (US-10.4.1).

## User Stories
US-10.1.1 (Set Profile Visibility), US-10.1.2 (Block a User), US-10.2.1 (Set Shelf Visibility), US-10.2.2 (Override Placement Visibility), US-10.2.3 (Set Blog Post Visibility), US-10.3.1 (Preview Content Visibility), US-10.4.1 (Search Engine Privacy)

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

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires Visibility module, Social context (blocking), ViewAs plug, VisibilityRecapJob, Blog context.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
