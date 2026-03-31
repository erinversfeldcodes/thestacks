# Issue #142: Blog Comments

## Summary
Add comment threads to blog posts. Readers can leave top-level comments and reply to existing ones. Authors can delete any comment on their post; commenters can delete their own. Block filtering silences comments from blocked users without visible placeholders. Covers US-13.1.1 and US-13.1.2.

## User Stories
US-13.1.1 Comment on a Blog Post, US-13.1.2 Block Filtering in Comments

## Goal
A published blog post has a visible comment section. Authenticated users can post comments and reply to existing comments. The system enforces ownership on deletion and silently filters blocked users' comments.

## Scope Check
- Does this issue touch more than 3 controllers? → No — 1 new controller (`CommentController`).
- Does this issue add more than 2 new endpoints? → No — POST + DELETE = 2 endpoints.
- Does this issue exceed ~300 lines of production code? → Migration + context ~100 LOC, controller ~80 LOC, Elm component ~150 LOC.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**Migration:** Add `op.post_comments` table:
```sql
id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
post_id     uuid NOT NULL REFERENCES op.blog_posts(id) ON DELETE CASCADE,
author_id   uuid NOT NULL REFERENCES op.users(id),
parent_id   uuid REFERENCES op.post_comments(id),  -- NULL for top-level
body        text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
created_at  timestamptz NOT NULL DEFAULT now()
```
Index: `(post_id, created_at DESC)`, `(parent_id)`.

**Proto:** Add `PostComment` message to `proto/stacks/content/v1/blog.proto`. Run `mix proto.sync` to generate the Ecto schema.

**`Stacks.Blog` additions:**
```elixir
list_comments(post_id, viewer_id)
  # → [Comment] with replies nested one level; blocks filtered
create_comment(post_id, author_id, attrs)
  # attrs: {body, parent_id (optional)}
  # → {:ok, Comment} | {:error, :post_not_found | :parent_not_found | changeset}
delete_comment(comment_id, requester_id)
  # → :ok | {:error, :unauthorized | :not_found}
  # post author may delete any comment; commenter may delete own
```

**Block filtering:** `list_comments/2` inner-joins to exclude any `author_id` that the viewer has blocked (via `Stacks.Social.blocked_user_ids/1`). Silent removal — no `[deleted]` marker.

**`CommentController`:**
- `POST /api/posts/:post_id/comments` → 201 or 404/422
- `DELETE /api/comments/:id` → 200 or 403/404

**Events emitted:** `post.comment_created`

**Elm additions to `Page.BlogPost`:**
- Comment list below post body
- Inline comment form (textarea + submit)
- Reply button on each top-level comment expands a nested form
- Delete button visible only to comment author and post author
- Author comments marked with `(author)` badge

## Reviewer Context
- `Stacks.Blog` context already handles `Post` CRUD — add comment functions to the same module.
- `mix proto.sync` must be run after adding the proto message; generated schema lands in `lib/stacks/gen/content/post_comment.ex`.
- One level of nesting only — replies cannot have replies.
- `list_comments/2` returns a flat list with `replies: [Comment]` on each top-level comment.

## Definition of Done
- [ ] Migration runs cleanly; `mix proto.sync` generates `PostComment` schema
- [ ] `list_comments/2` excludes comments from users the viewer has blocked
- [ ] `delete_comment/2` returns `:unauthorized` for non-author non-post-owner
- [ ] POST /api/posts/:id/comments returns 404 for unpublished posts
- [ ] Elm renders threaded comments correctly (one level deep)
- [ ] Author badge visible on post author's own comments
- [ ] Tests for block filtering logic
- [ ] Tests for ownership rules on deletion
- [ ] `just verify` passes

## Dependencies
None (Blog context exists; Social.blocked_user_ids needed — implement inline if not present).

## Agent Assignment
elixir-agent, elm-agent

## Progress Notes
