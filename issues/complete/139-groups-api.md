# Issue #139: Groups — API Endpoints & Router Wiring

## Summary
Expose the group context functions (Issue #138) over HTTP. Five endpoints: create group, get group, invite member, accept/decline invitation, leave group, and remove member. Fully auth-guarded via Guardian pipeline.

## User Stories
US-11.1.1, US-11.1.2, US-11.1.3, US-11.1.4

## Goal
A client can create a group, invite users, and manage membership through the REST API. All group operations return JSON and are covered by integration tests.

## Scope Check
- Does this issue touch more than 3 controllers? → No — 2 controllers: `GroupController`, `GroupMemberController`.
- Does this issue add more than 2 new endpoints? → Yes (7 endpoints) — acceptable for a single bounded domain.
- Does this issue exceed ~300 lines of production code? → Borderline — 2 controllers + router additions.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**Routes (`StacksWeb.Router`):**
```
scope "/api", StacksWeb do
  pipe_through [:api, :auth]

  resources "/groups", GroupController, only: [:create, :show]
  post   "/groups/:id/invitations",         GroupMemberController, :invite
  put    "/groups/:id/invitations/:inv_id/accept",  GroupMemberController, :accept
  put    "/groups/:id/invitations/:inv_id/decline", GroupMemberController, :decline
  delete "/groups/:id/members/:user_id",    GroupMemberController, :remove
  delete "/groups/:id/members/me",          GroupMemberController, :leave
end
```

**`GroupController`:**
- `create/2` — delegates to `Social.create_group/2`; returns 201 with group JSON
- `show/2` — delegates to `Social.get_group/2`; returns 200 or 404

**`GroupMemberController`:**
- `invite/2` — POST body: `{invitee: email_or_username}`; returns 201 invitation JSON or 404/409
- `accept/2`, `decline/2` — returns 200 or 403/404
- `remove/2` — returns 200 or 403/404
- `leave/2` — returns 200 or 422 (owner attempting to leave)

**JSON views** — `GroupJSON`, `GroupInvitationJSON` (use `StacksWeb.JSON` convention with `data` key).

## Reviewer Context
- Follow the existing controller pattern in `BookshelfPlacementController` for 403 vs 404 disambiguation.
- Guardian `current_resource(conn)` gives the authenticated user.
- Use `put_status(:created)` + `render(conn, :show, ...)` not bare `json/2`.

## Definition of Done
- [ ] All 7 endpoints return correct status codes
- [ ] Unauthenticated requests return 401
- [ ] Non-owner remove returns 403
- [ ] Owner leave returns 422 with reason
- [ ] Integration tests cover happy path and all listed error cases
- [ ] `just verify` passes

## Dependencies
#138 (Groups context)

## Agent Assignment
elixir-agent

## Progress Notes
