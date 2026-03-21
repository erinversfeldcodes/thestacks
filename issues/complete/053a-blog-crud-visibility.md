# Issue #053a: Blog CRUD + Visibility Ceiling Enforcement

## Summary
Build the blog context with post CRUD operations, visibility ceiling enforcement, and controller endpoints.

## User Stories
US-12.1 — "As a user, I want to write blog posts about books I've read."

## Goal
Users can create, edit, publish, and delete blog posts. Post visibility respects the profile visibility ceiling — a post can't be more visible than the user's profile.

## Scope Check
- 1 context (`Stacks.Blog`)
- 1 controller (`BlogController`)
- 0 new workers
- ~250 LOC

## Wiring
- [x] This issue includes router wiring for blog endpoints.

## Technical Requirements

1. **`Stacks.Blog` context**:
   - `create_post/2` — accepts user_id + attrs, creates with `status: "draft"`, `visibility: "owner"`
   - `update_post/3` — accepts post_id + user_id + attrs, validates ownership
   - `publish_post/2` — sets `published_at`, emits `blog.post_published` event
   - `unpublish_post/2` — clears `published_at`
   - `delete_post/2` — validates ownership, soft or hard delete
   - `get_post/1` — returns post with associations preloaded
   - `list_user_posts/1` — returns all posts for a user
   - `list_published_posts/0` — returns platform-visible published posts
   - Visibility: `validate_visibility_ceiling/3` on create/update — post visibility can't exceed profile visibility

2. **`BlogController`**:
   - `POST /api/posts` — create draft
   - `GET /api/posts` — list published posts (public)
   - `GET /api/posts/:id` — show post (visibility-gated)
   - `PUT /api/posts/:id` — update post
   - `PUT /api/posts/:id/publish` — publish post
   - `DELETE /api/posts/:id` — delete post
   - Authenticated except public `GET` endpoints

3. **Events**: `blog.post_published`, `blog.post_updated`, `blog.post_deleted`

## Reviewer Context
- `Stacks.Blog` context module exists as an empty stub
- Post and PostBookAssociation schemas already exist with all fields
- `Visibility.validate_visibility_ceiling/3` already exists and works
- Blog tables already created in migration 20260319000004

## Definition of Done
- [ ] Blog CRUD works via API
- [ ] Visibility ceiling enforced on create/update
- [ ] `blog.post_published` event emitted on publish
- [ ] Ownership validated on update/delete
- [ ] Public listing shows only published platform-visible posts
- [ ] Tests cover CRUD, visibility, ownership, events
- [ ] `just verify` passes

## Dependencies
- Issue #047 (visibility — complete)
- Issue #043 (blog tables — complete)

## Agent Assignment
elixir-agent

## Progress Notes
