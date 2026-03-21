# Plan: Issue #053a — Blog CRUD + Visibility Ceiling

## Context

Blog tables exist (migration 20260319000004). Post and PostBookAssociation schemas exist with all fields. Blog context is an empty stub. `Visibility.validate_visibility_ceiling/3` is implemented. dbt staging models for blog are complete.

## Key Decisions

1. **Draft-first workflow** — posts created as drafts (visibility: "owner"), published explicitly via separate endpoint.
2. **Hard delete** — no soft delete for posts. If deleted, associations are cascade-deleted by FK constraint.
3. **Visibility ceiling via existing infrastructure** — `Visibility.validate_visibility_ceiling/3` already handles the rank comparison.
4. **Public listing** — published posts with visibility "platform" are visible to all. "group" posts require group membership (deferred until groups feature is wired).

## Implementation Steps

### Step 1: Implement Blog context
- `create_post/2` — insert with defaults, validate ceiling
- `update_post/3` — ownership check, validate ceiling on visibility change
- `publish_post/2` — set published_at, emit event
- `unpublish_post/2` — clear published_at
- `delete_post/2` — ownership check, Repo.delete
- `get_post/1` — preload :user, :book_associations
- `list_user_posts/1` — all posts for user_id
- `list_published_posts/0` — where published_at not nil and visibility "platform"

### Step 2: Create BlogController
- Standard CRUD endpoints
- Auth: Guardian.Plug.current_resource for ownership
- Public GET uses optional auth pipeline
- Visibility: resolve_visibility on show

### Step 3: Wire routes
- Public: `GET /api/posts`, `GET /api/posts/:id`
- Authenticated: `POST /api/posts`, `PUT /api/posts/:id`, `PUT /api/posts/:id/publish`, `DELETE /api/posts/:id`

### Step 4: Events
- `blog.post_published` on publish
- `blog.post_updated` on update
- `blog.post_deleted` on delete

## File Inventory

### New files
- `apps/core/lib/stacks_web/controllers/blog_controller.ex`
- `apps/core/test/stacks/blog_test.exs`
- `apps/core/test/stacks_web/controllers/blog_controller_test.exs`

### Modified files
- `apps/core/lib/stacks/blog/blog.ex` — implement CRUD functions
- `apps/core/lib/core_web/router.ex` — add blog routes
- `apps/core/test/support/factory.ex` — add post factory
