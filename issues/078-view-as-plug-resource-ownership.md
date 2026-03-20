# Issue #078: ViewAsPlug — Resource Ownership Check for Regular Users

## Summary
`ViewAsPlug` currently gates on `role: "owner"` (platform administrator), but US-10.3.1 requires that any user can preview their own content as different viewer types. A regular user visiting their own bookshelf gets 403 when using `?view_as=unauthenticated`, which is wrong. The plug also needs to be wired into the router.

## User Stories
US-10.3.1 (preview content visibility)

## Goal
`ViewAsPlug` should allow any authenticated user to use `?view_as` when viewing **their own** content (bookshelf, profile). The platform-admin `role: "owner"` check should be replaced with a resource-ownership check: the current user must be the owner of the content being previewed.

## Technical Requirements

**`ViewAsPlug.handle_view_as/2` changes:**
- Remove `owner?(%{role: "owner"})` check
- Instead: check `conn.assigns[:resource_owner_id]` (set by individual controllers when they load a resource) against `current_user.id`
- If they match → allow ViewAs
- If they don't match → 403 (users cannot preview other people's content as different viewers)
- If no resource owner context is available → 403

**Controller responsibility:** Any controller that supports ViewAs must assign `resource_owner_id` before ViewAsPlug runs. For `BookshelfController.show/2`, this means assigning `conn.assigns[:resource_owner_id] = bookshelf.user_id` before the plug fires.

**Alternatively (simpler):** Move the ownership check into each controller's action rather than into the plug, and have the plug remain a pure "parse and assign `view_as_context`" mechanism — with controllers deciding whether to honour the context based on ownership. Evaluate both approaches.

**Router wiring:** Add `ViewAsPlug` to the bookshelf and profile routes scope (not globally — only on content-display routes).

**`"group:<group_id>"` perspective:** Stub returning 422 with `"not_implemented"` until groups feature (Issue #011) is complete. Currently returns `{:group, id}` which has no matching Visibility clause.

## Definition of Done
- [ ] Regular users can use `?view_as=unauthenticated` and `?view_as=platform` on their own bookshelves
- [ ] Non-owners receive 403 when attempting ViewAs on other users' content
- [ ] `ViewAsPlug` wired into router for bookshelf/profile display routes
- [ ] `"group:<id>"` perspective returns 422 `not_implemented` (until Issue #011)
- [ ] `ViewAsPlug` tests updated to cover ownership cases (owner allowed, non-owner denied)
- [ ] `mix test` passes, `mix credo --strict` clean

## Dependencies
Issue #047 (ViewAsPlug must exist — complete), Issue #011 (groups, deferred — groups perspective stubs to 422)

## Agent Assignment
elixir-agent

## Progress Notes
