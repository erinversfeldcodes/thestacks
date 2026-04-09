# Issue #123: E2E Test Suite — Blog & LLM Associations

## Summary
Comprehensive E2E test coverage for blog CRUD with visibility (US-12.1.1), LLM book association worker (US-12.1.2), and blog archive browsing with visibility filtering (US-12.1.3).

## User Stories
US-12.1.1 (Write a Blog Post), US-12.1.2 (LLM Book Associations on a Post), US-12.1.3 (Browse Another User's Blog)

## Goal
Validate blog post lifecycle (create/save/publish/delete), two-step publish flow, LLM association worker with Together AI mock, confirm/dismiss association ownership checks, blog archive visibility filtering, and "My Writing" cross-reference in book detail.

## Scope Check
- Does this issue touch more than 3 controllers? No (BlogController only).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (all blog-related).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **New post editor**: Navigate to `/blog/new` -> title input, body textarea, visibility selector
- **Save draft**: Enter title/body -> click "Save Draft" -> editor switches to Edit mode
- **Publish flow**: Save draft -> click "Publish" -> post gets `published_at` set
- **Blog archive**: Navigate to `/blog` -> see list of post cards with title, date, preview
- **"New Post" link**: Only visible to authenticated users on archive page
- **Post detail page**: Click post card -> full post with title, date, body content
- **Book associations section**: "Books from my shelves" with confidence badges (high/medium/low)
- **Owner actions**: Confirm/Dismiss buttons visible only to post owner
- **Non-owner view**: Only confirmed (visible) associations shown, no reasoning field
- **Edit link**: "Edit" link visible only to post owner on detail page
- **Empty archive**: "No posts yet." message when no posts exist
- **Visibility badge**: `Components.VisibilityBadge` renders on post summaries
- **Writing assistant panel**: Collapsible assistant panel present in editor; notification dot visible after save triggers nudge; dot absent before first nudge
- **Publish gate**: If assistant has unresolved observation, "There's something unresolved here — publish anyway?" prompt appears before publish; user can proceed or dismiss

### 2. Playwright Navigation & Visual Tests
- **Auth guard**: Unauthenticated user at `/blog/new` sees login page
- **Blog archive public**: `/blog` accessible without auth (optional auth)
- **Post detail public**: `/blog/posts/:id` accessible for public posts without auth
- **Loading/error states**: Loading spinners and error messages for blog pages

### 3. API Endpoint Tests
- `POST /api/blog/posts` — 201 with post data, default visibility "owner"
- `POST /api/blog/posts` — 422 on missing title/body, visibility_ceiling violation
- `PUT /api/blog/posts/:id` — 200 on update, 404 not found, 403 unauthorized, 422 visibility_ceiling
- `DELETE /api/blog/posts/:id` — 200 `{ deleted: true }`, 404 not found, 403 unauthorized
- `POST /api/blog/posts/:id/publish` — 200 with `published_at` set, 404/403 errors
- `GET /api/blog/posts?user_id=<id>` — 200 with filtered posts
- `GET /api/blog/posts?user_id=<id>` — owner sees all posts including unpublished, ordered by `created_at desc`
- `GET /api/blog/posts?user_id=<id>` — non-owner sees only published, ordered by `published_at desc`, filtered by `Visibility.can_view?`
- `GET /api/blog/posts?user_id=<id>` — 422 when `user_id` missing
- `GET /api/blog/posts/:id` — 200 with post + associations
- `GET /api/blog/posts/:id` — owner sees all associations with `reasoning`
- `GET /api/blog/posts/:id` — non-owner sees only visible associations without `reasoning`
- `GET /api/blog/posts/:id` — 404 when post not found or not visible
- `PUT /api/blog/posts/:post_id/associations/:id/confirm` — 200 sets `visible: true`
- `PUT /api/blog/posts/:post_id/associations/:id/dismiss` — 200 sets `visible: false`
- Confirm/dismiss — 404 not found, 403 unauthorized (not post owner)

### 4. Database Assertion Tests
- `op.blog_posts` record created with `user_id`, `title`, `body`, `visibility` (default "owner"), `published_at: nil`
- Publish sets `published_at` to current timestamp
- Delete removes record from `op.blog_posts`
- `op.post_book_associations` created with `post_id`, `book_id`, `confidence`, `reasoning`, `source: "llm"`, `visible: true`
- Confirm sets `visible: true`, dismiss sets `visible: false`
- `Blog.list_user_posts/2` owner query: all posts by `created_at desc`
- `Blog.list_user_posts/2` non-owner query: published only by `published_at desc` + visibility filter
- `Blog.get_post_for_viewer/2` returns nil for non-visible posts
- `Blog.list_posts_for_book/2` cross-reference: joins posts with associations where `visible == true` and published

### 5. Event Flow Tests
- `blog.post_created` emitted with `{ user_id, title, visibility }`
- `blog.post_updated` emitted on update
- `blog.post_published` emitted on publish -> triggers `BlogAssociationHandler` + `DbtRefreshHandler`
- `blog.post_updated` emitted on save -> triggers `DbtRefreshHandler` + `WritingAssistantNudgeHandler` (debounced, max once per 10 min per post)
- `blog.post_deleted` emitted on delete -> triggers `DbtRefreshHandler`
- `blog.associations_suggested` emitted by worker with `{ book_ids, count }`
- `blog.association_confirmed` emitted with `{ post_id, book_id }`
- `blog.association_dismissed` emitted with `{ post_id, book_id }`
- `blog.associations_suggested` triggers `CacheInvalidationHandler` (book detail cache)
- No events emitted by blog reading (archive/detail)

### 6. Background Job Tests
- `PostBookAssociationWorker` — queue `:default`, args `{ post_id }`, max_attempts 3
- Trigger chain: `publish_post` -> `blog.post_published` -> `BlogAssociationHandler` -> enqueue worker
- Worker fetches post and up to 200 books with author preload
- Worker builds prompt with post body (truncated 4000 chars) + book list
- Worker calls `together_client().complete(prompt, max_tokens: 1024, temperature: 0.2)`
- Worker parses JSON response as `[{ book_id, confidence, reasoning }]`
- Worker persists associations via `Blog.associate_book/3` with `source: "llm"`
- No books in catalogue: worker skips LLM call, returns `:ok`
- Post not found: worker logs warning, returns `:ok`
- LLM parse failure: worker logs warning, returns `:ok` (no retry)
- LLM circuit breaker open: returns `{:error, :circuit_open}` for retry

### `WritingAssistantNudgeWorker` (triggered by save, debounced)
- Trigger chain: `blog.post_updated` -> `WritingAssistantNudgeHandler` (debounced, max once per 10 min) -> enqueue worker
- Worker calls `Stacks.AI.WritingAssistantClient` (separate from `TogetherClient`) using `Llama-3.3-70B-Instruct-Turbo`
- Worker stores result in `op.blog_assistant_sessions`
- Debounce: second save within 10 min does NOT enqueue a second worker for same post
- Worker skips if user has not granted `consent_writing_assistant`
- **Not to be confused with `PostBookAssociationWorker`**: different client, different model, different circuit breaker (`:writing_assistant_fuse`)

### 7. External Service Tests
- Together AI mock (association worker): returns valid JSON array of associations; circuit breaker `:together_ai_fuse` (3 failures in 2 min); `{:error, :api_key_missing}` when key not configured; mock via `Application.get_env(:core, :together_client)` -> `MockTogetherClient`
- Writing assistant mock (nudge worker): separate mock via `Application.get_env(:core, :writing_assistant_client)` -> `MockWritingAssistantClient`; circuit breaker `:writing_assistant_fuse` tested independently

### 8. Storage Tests
- N/A

### 9. Cache Tests
- `BookDetailCache` invalidated on `blog.associations_suggested` event
- Ensures "My Writing" section on book detail overlays reflects new associations

### 10. dbt Model Tests
- `blog.post_published`, `blog.post_updated`, `blog.post_deleted` trigger `DbtRefreshHandler`

### 11. Elm State Machine Tests
- `Page.Blog.Editor` new mode init: `mode = New, title = "", body = "", visibility = Owner, saving = NotAsked`
- `Page.Blog.Editor` edit mode: `loading = Loading`, fires `Api.getBlogPost`
- `SetTitle`, `SetBody`, `SetVisibility` update fields, reset saving
- `SaveDraft` -> `Api.createBlogPost` (New) or `Api.updateBlogPost` (Edit) -> `SaveCompleted`
- `SaveCompleted (Ok newId)` -> switches mode to `Edit newId` if was New
- `Publish` -> sets `publishing = Loading, saving = Loading` -> save first -> on success fires publish
- `PublishCompleted (Ok _)` -> `publishing = Success ()`
- `Page.Blog.Editor` includes `assistantPanel : AssistantPanelState` and `nudgeAvailable : Bool` fields (see US-12.2.1 for full state machine)
- `Page.Blog.Archive` init: fires `Api.getBlogPosts` -> `PostsLoaded`
- `Page.Blog.Post` init: fires `Api.getBlogPost` -> `PostLoaded`
- `ConfirmAssociation id` -> `Api.confirmAssociation` -> `AssociationActionCompleted` -> reloads post
- `DismissAssociation id` -> same pattern
- `Components.BookAssociations`: confidence badge thresholds (>=80% high, >=50% medium, <50% low)

### 12. Metrics & Telemetry Tests
- Blog CRUD operation counts via events
- Draft vs publish ratio
- `PostBookAssociationWorker` success/failure rates
- Circuit breaker state transitions for Together AI
- Association creation count per worker run
- Association confirm/dismiss counts
- `WritingAssistantNudgeWorker` success/failure rates; debounce enforcement (max 1 per 10 min per post)
- Circuit breaker state transitions for `:writing_assistant_fuse` (independent of `:together_ai_fuse`)
- Blog post read counts (owner vs non-owner)
- Blog archive list counts
- Visibility filtering drop rate

## Reviewer Context
- The two-step publish flow: save first, then publish on success. Both are separate API calls.
- `BlogAssociationHandler` is triggered by `blog.post_published` event, not `blog.post_created`.
- LLM prompt includes post body truncated to 4000 chars and formatted book list (`id: "title" by author`).
- Non-owners only see associations with `visible == true` and without `reasoning` field.
- **Two distinct LLM flows in this issue**: `PostBookAssociationWorker` (post-publish, `Llama-3-8b-chat-hf`, `TogetherClient`, `:together_ai_fuse`) vs `WritingAssistantNudgeWorker` (on-save, `Llama-3.3-70B-Instruct-Turbo`, `WritingAssistantClient`, `:writing_assistant_fuse`). These must use separate mocks and are tracked separately in cost reporting.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires Blog context, BlogController, PostBookAssociationWorker, Together AI mock client.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
