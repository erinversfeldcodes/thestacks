# Issue #150: Visibility Grants CRUD

## Summary
`visibility_grant_changeset/2` exists in `Stacks.Social` but none of the CRUD operations are implemented. A visibility grant lets a user share a specific bookshelf with a specific group (for `visibility = 'group'` bookshelves). Without this, the group-scoped visibility tier is non-functional end-to-end.

## User Stories
US-10.x (privacy and visibility controls — group-scoped access)

## Goal
A user can grant a specific group access to a bookshelf set to `visibility = 'group'`. They can list current grants and revoke them. The visibility resolution logic in `Stacks.Visibility` respects grants when determining whether a viewer can see a shelf.

## Scope Check
- Does this issue touch more than 3 controllers? → No — `VisibilityGrantController` only.
- Does this issue add more than 2 new endpoints? → No — POST + DELETE = 2.
- Does this issue exceed ~300 lines of production code? → No — context ~80 LOC, controller ~60 LOC.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**`Stacks.Social` additions:**
```elixir
grant_visibility(bookshelf_id, group_id, grantor_id)
  # → {:ok, VisibilityGrant} | {:error, :unauthorized | :already_granted | changeset}
  # Only bookshelf owner may grant

revoke_visibility(bookshelf_id, group_id, grantor_id)
  # → :ok | {:error, :unauthorized | :not_found}

list_visibility_grants(bookshelf_id, requester_id)
  # → [VisibilityGrant with group: Group] | {:error, :unauthorized}

has_visibility_grant?(bookshelf_id, viewer_id)
  # → bool — true if viewer is member of any group granted access to bookshelf
```

**Update `Stacks.Visibility.resolve/2`:**
- When `bookshelf.visibility == "group"` and viewer is not the owner: call `Social.has_visibility_grant?(bookshelf_id, viewer_id)`.
- Currently this check is missing — group-visibility bookshelves are inaccessible to all non-owners.

**Routes:**
```
scope "/api", StacksWeb do
  pipe_through [:api, :auth]
  post   "/bookshelves/:bookshelf_id/grants",            VisibilityGrantController, :create
  get    "/bookshelves/:bookshelf_id/grants",            VisibilityGrantController, :index
  delete "/bookshelves/:bookshelf_id/grants/:group_id",  VisibilityGrantController, :delete
end
```

**`VisibilityGrantController`:**
- `create/2`: body `{ "group_id": "..." }` → 201 or 403/409
- `index/2`: 200 with list of grants (group name, id)
- `delete/2`: 200 or 403/404

## Reviewer Context
- `VisibilityGrant` schema is already generated at `lib/stacks/gen/social/visibility_grant.ex` — do not re-create.
- `Stacks.Visibility` is at `lib/stacks/visibility.ex` — the `resolve/2` function is the integration point.
- Group membership check needed in `has_visibility_grant?/2` — query `group_members` table for viewer_id in any granted group.
- `grant_visibility/3` should verify the bookshelf's `visibility` field is `"group"` before proceeding — granting access on a public shelf is a no-op and should return `{:error, :not_applicable}`.

## Definition of Done
- [ ] `has_visibility_grant?/2` correctly returns true when viewer is in a granted group
- [ ] `Stacks.Visibility.resolve/2` uses grants for group-visibility bookshelves
- [ ] Granting access on a non-group-visibility shelf returns `{:error, :not_applicable}`
- [ ] `revoke_visibility/3` returns `:unauthorized` for non-owners
- [ ] API returns correct status codes for all paths
- [ ] Tests for visibility resolution: owner sees shelf, group member sees shelf, non-member cannot
- [ ] `just verify` passes

## Dependencies
#138 (Groups context — group membership queries), Issue #047 (Visibility infrastructure — already complete)

## Agent Assignment
elixir-agent

## Progress Notes
