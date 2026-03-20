# Issue #076: Block/Unblock HTTP API Endpoints

## Summary
`Social.block_user/2` and `Social.unblock_user/2` are implemented and `resolve_visibility/2` enforces blocks, but there are no HTTP endpoints. The Elm frontend has no way to trigger a block or unblock, and there is no endpoint to list blocked users for the Privacy Settings screen.

## User Stories
US-10.1.2 (block a user)

## Goal
Expose block, unblock, and list-blocked endpoints so that the Elm frontend can drive the full block/unblock UX including the blocked users list in Privacy Settings.

## Technical Requirements

**New controller: `StacksWeb.SocialController`** (or add to `UserSettingsController` if narrow):
- `POST /api/users/:id/block` — calls `Social.block_user(current_user.id, params["id"])`. Returns 200 on success, 404 if target user not found, 422 if blocking self.
- `DELETE /api/users/:id/block` — calls `Social.unblock_user(current_user.id, params["id"])`. Returns 200 on success, 404 if no block exists.
- `GET /api/settings/blocked-users` — returns paginated list of users blocked by current user. Response: `%{blocked_users: [...], total: N}`.

**Events:** `block_user/2` and `unblock_user/2` must emit `social.user_blocked` and `social.user_unblocked` events via `Stacks.Events.emit/1` (currently deferred).

**Router:** Add routes under `authenticated_scope` in `router.ex`.

**Rate limiting:** Block/unblock actions must be rate-limited (reuse existing `RateLimiter` plug, action `:block`).

**JSON response for blocked user:**
```json
{
  "id": "uuid",
  "display_name": "...",
  "blocked_at": "2026-03-19T..."
}
```

## Definition of Done
- [ ] `POST /api/users/:id/block` returns 200 / 404 / 422 correctly
- [ ] `DELETE /api/users/:id/block` returns 200 / 404 correctly
- [ ] `GET /api/settings/blocked-users` returns paginated blocked-users list
- [ ] `social.user_blocked` and `social.user_unblocked` events emitted
- [ ] All three endpoints covered by controller tests (auth, success, error cases)
- [ ] Routes added to router
- [ ] Rate limiting applied to block/unblock actions
- [ ] `mix test` passes, `mix credo --strict` clean

## Dependencies
Issue #047 (Social.block_user/2 must exist — complete), Issue #043 (user_blocks table must exist)

## Agent Assignment
elixir-agent

## Progress Notes

**2026-03-19 — Complete. All gates passed.**

- `StacksWeb.SocialController` added with `block/2`, `unblock/2`, `blocked_users/2`
- `Social.list_blocked_users/2` added — joins `user_blocks` → `users`, returns `{[map()], count}`
- Routes: `POST /api/users/:id/block`, `DELETE /api/users/:id/block`, `GET /api/settings/blocked-users`
- Events already emitted by `block_user/2` and `unblock_user/2` (implemented in #047)
- `social_controller.ex` hit 100% coverage immediately
- 542 tests, 0 failures; Credo clean
