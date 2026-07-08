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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #123)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #123 covers three user stories — US-12.1.1 (Write a
Blog Post), US-12.1.2 (LLM Book Associations on a Post), US-12.1.3 (Browse
Another User's Blog). The matrix is 13 layers × 3 US, with happy/sad columns
per cell (78 cells total). The assertion inventory per layer is taken from
each US doc (`docs/user_stories/US-12.1.{1,2,3}-*.md`) cross-referenced with
Issue #123's 12 Technical-Requirements sections.

**Feature status — PARTIALLY implemented.** The blog-post + LLM-association
half is fully implemented server-side:
- `Stacks.Blog` context (`apps/core/lib/stacks/blog/blog.ex`, 516 LOC):
  `create_post/2`, `update_post/3`, `publish_post/2`, `delete_post/2`,
  `get_post/1`, `get_post_for_viewer/2`, `list_user_posts/2`,
  `list_posts_for_book/2`, `associate_book/3`, `confirm_association/2`,
  `dismiss_association/2`, `list_associations/1`, `tighten_posts_to_ceiling/2`.
- `StacksWeb.BlogController` — all 9 endpoints wired.
- `Stacks.Workers.PostBookAssociationWorker` (queue `:default`, max_attempts 3)
  → `Stacks.AI.TogetherClient` (`:together_ai_fuse` circuit breaker,
  `Llama-3-8b-chat-hf`) with `Stacks.AI.MockTogetherClient` for tests.
- `Stacks.Blog.Handlers.BlogAssociationHandler` + `Stacks.Books.Handlers.CacheInvalidationHandler`,
  both wired in `Stacks.Events.Registry` (`blog.post_published`,
  `blog.post_updated`, `blog.post_deleted`, `blog.associations_suggested`).
- Elm pages `Page.Blog.{Editor,Archive,Post}` + `Components.BookAssociations`
  + `Types.BlogPost` all exist.
- dbt models `stg_blog_posts`, `stg_post_book_associations`,
  `int_blog_engagement`, `mart_blog_activity`, `mart_llm_faithfulness`
  (all proto-generated).

**NOT implemented — the WritingAssistant nudge half (blocked on US-12.2.1).**
Issue #123 §6/§7/§1 additionally require `WritingAssistantNudgeWorker`,
`Stacks.AI.WritingAssistantClient`, `:writing_assistant_fuse`,
`WritingAssistantNudgeHandler`, `op.blog_assistant_sessions`,
`consent_writing_assistant`, and the editor's assistant-panel nudge UI. **None
of these exist** (verified: no `writing_assistant` files under `apps/`, no
`blog_assistant_sessions` migration, `blog.post_updated` in the registry wires
only `DbtRefreshHandler`). US-12.1.1 §7 itself labels this "planned (US-12.2.1)
… Not yet implemented / Not yet wired in `Events.Registry`". These assertions
are therefore **blocked on feature implementation**, not test gaps, and are
tracked separately in the punch list.

---

### Framework-layer summary

| Layer       | US-12.1.1 (write) | US-12.1.2 (LLM assoc) | US-12.1.3 (browse) |
|-------------|-------------------|-----------------------|--------------------|
| Elixir      | ✅ CRUD context + controller solid (blog_test 34, blog_controller_test 24); gaps: event payloads, negative-emission, DbtRefresh enqueue | ⚠️ worker + confirm/dismiss covered; assoc-event emission + cost tracking + TogetherClient fuse untested | ⚠️ list_user_posts solid; get_post_for_viewer + list_posts_for_book untested; block-hiding untested |
| Elm unit    | ❌ zero `Page.Blog.Editor` tests | ⚠️ proto decoders only; no `ConfirmAssociation`/`BookAssociations` badge tests | ❌ no `Page.Blog.Archive`/`Post` load-state tests (comment Msgs only) |
| Python      | n/a — no vision service in blog | n/a — LLM is Together AI (Elixir client), not Python vision | n/a |
| E2E         | ❌ no `e2e/tests/blog*.spec.ts` exists at all | ❌ same | ❌ same |
| dbt         | ⚠️ stg_blog_posts + generic id/timestamp tests only | ⚠️ stg_post_book_associations generic only; no accepted_values/relationships | n/a — read path (US-12.1.3 §11 N/A) |
| WritingAsst | ❌ blocked — worker/client/fuse/table/UI not implemented (US-12.2.1) | n/a — separate flow | n/a |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks/blog_test.exs` — 34 tests (context CRUD, visibility, ceiling, event counts)
- `apps/core/test/stacks_web/controllers/blog_controller_test.exs` — 24 tests (all 9 endpoints)
- `apps/core/test/stacks/blog/post_test.exs` — 5 tests (post changeset)
- `apps/core/test/stacks/blog/post_book_association_test.exs` — 5 tests (association changeset)
- `apps/core/test/stacks/blog/handlers/blog_association_handler_test.exs` — 2 tests (enqueue + ignore)
- `apps/core/test/stacks/workers/post_book_association_worker_test.exs` — 5 tests
- `apps/core/test/stacks/books/handlers/cache_invalidation_handler_test.exs` — 2 blog.associations_suggested tests
- `frontend/tests/BlogPostCommentTest.elm` — comment-only tests on `Page.Blog.Post` (US-13, NOT associations)
- `frontend/tests/ProtoDecoderTest.elm` — BlogPost/Association proto decoder round-trips
- `dbt/models/staging/schema.yml` — generic id/timestamp tests on stg_blog_posts + stg_post_book_associations
- No `together_client` test, no `e2e/tests/blog*.spec.ts`, no Elm Editor/Archive tests.

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **19** |
| ⚠️ shallow | **10** |
| ❌ missing | **12** |
| n/a (covered higher up / not applicable / by-design) | **37** |

78 cells total (13 layers × 3 US × happy/sad). Pre-implementation baseline;
Issue #123's DoD requires regenerating this audit to 0 ❌ / 0 ⚠️ after the
punch list lands. Several ❌ items (WritingAssistant, cost tracking) are
**blocked on feature implementation** and may spawn new issues under the
scope-lock rule.

---

### Full audit tables

#### Layer 1: API Calls

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | ✅ blog_controller_test.exs — "creates a draft post when authenticated" (201, `visibility=owner`, `published_at=nil`), "updates a post when called by the owner", "deletes a post when called by the owner" (`{deleted: true}`), "publishes a draft post" (`published_at != nil`). | ✅ | ✅ blog_controller_test.exs — "returns 422 when required fields are missing", "returns 422 when visibility exceeds ceiling", "returns 404 for nonexistent post" (update/delete/publish ×3). | ✅ |
| 12.1.2 | ⚠️ blog_controller_test.exs — confirm "sets visible to true and returns association", dismiss "sets visible to false and returns association". BUT `GET /api/blog/posts/:id` is never asserted to return the `associations` array, and reasoning-field inclusion/omission by owner vs non-owner (US-12.1.2 §3) has **no** test at the HTTP layer. | ⚠️ | ✅ blog_controller_test.exs — confirm/dismiss "returns 403 when called by non-owner", "returns 404 for nonexistent post", "returns 404 for nonexistent association". | ✅ |
| 12.1.3 | ⚠️ blog_controller_test.exs — index "returns published posts for a user (unauthenticated)", "owner sees all posts including drafts"; show "shows a published platform-visible post to unauthenticated viewer", "owner can see their own owner-only post". BUT ordering (`created_at desc` owner vs `published_at desc` non-owner, US-12.1.3 §3) and the associations payload on show are unasserted. | ⚠️ | ✅ blog_controller_test.exs — "returns 422 when user_id is missing", "returns 404 for owner-only post viewed by non-owner", "returns 404 for nonexistent post". | ✅ |

#### Layer 2: Auth & Middleware Guards

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | ✅ blog_controller_test.exs — authenticated create/update/delete/publish via `auth_conn/2`; ownership guard "returns 403 when called by a non-owner" (update/delete/publish). | ✅ | ✅ blog_controller_test.exs — "returns 401 when unauthenticated" on POST/PUT/DELETE/publish (all four mutation endpoints guarded). | ✅ |
| 12.1.2 | ✅ blog_controller_test.exs — confirm/dismiss called by authenticated owner (`auth_conn`); `GET /:id` owner path "owner can see their own owner-only post". | ✅ | ⚠️ blog_controller_test.exs — confirm/dismiss "returns 403 when called by non-owner" covers ownership. BUT there is **no 401-unauthenticated** test for `PUT …/associations/:id/confirm` or `/dismiss` (both are `:authenticated`-scoped and untested for the missing-token case). | ⚠️ |
| 12.1.3 | ✅ blog_controller_test.exs — optional-auth index/show accessible unauthenticated ("returns published posts … (unauthenticated)", "shows a published platform-visible post to unauthenticated viewer"). | ✅ | ⚠️ Visibility ceiling covered ("returns 404 for owner-only post viewed by non-owner"). BUT the bidirectional block check (`Social.blocked?/2`, US-12.1.3 §4) that should hide a blocked user's posts has **no** blog-level test. | ⚠️ |

#### Layer 3: Database Interactions

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | ✅ blog_test.exs — create_post "creates a post with valid attrs" (fields + `user_id` + `published_at=nil`), "defaults to draft (visibility: owner)"; publish "sets published_at timestamp"; delete "deletes a post" (`get_post` → nil); update "updates a post". post_test.exs — 5 changeset validity tests. | ✅ | ✅ blog_test.exs — "returns changeset error when required fields are missing", "enforces visibility ceiling" (create + update), update/publish/delete ":unauthorized when called by a non-owner"; post_test.exs — invalid without title/body/visibility. | ✅ |
| 12.1.2 | ✅ post_book_association_test.exs — "is valid with post, book, confidence, and source", "visible defaults to true in changeset"; worker_test.exs — "associates books when LLM returns valid JSON" persists `source=llm`, `confidence`, `reasoning`; blog_controller_test confirm/dismiss round-trips `visible` true/false. | ✅ | ✅ post_book_association_test.exs — "is invalid without post_id", "is invalid without book_id", "is invalid with source not in allowed values". | ✅ |
| 12.1.3 | ⚠️ blog_test.exs — list_user_posts "owner sees all posts including unpublished drafts", "non-owner sees only published posts", "unauthenticated viewer sees only published posts". BUT `get_post_for_viewer/2` and the `list_posts_for_book/2` cross-reference JOIN (US-12.1.3 §5, book-detail "My Writing") have **zero** direct context tests. | ⚠️ | ⚠️ blog_test.exs — "non-owner cannot see owner-only posts even if published", "unauthenticated sees only published + platform-visible posts". BUT `get_post_for_viewer/2` returning `nil` for a non-visible/blocked post (US-12.1.3 §5) is untested at the context level. | ⚠️ |

#### Layer 4: Event Flow & Lifecycle

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | ⚠️ blog_test.exs — "emits blog.post_created event", "emits blog.post_updated event", "emits blog.post_published event", "emits blog.post_deleted event". BUT each only asserts an `event_log` **count** increment; the payload shapes `{user_id, title, visibility}` / `{user_id}` (US-12.1.1 §6) are never asserted. | ⚠️ | ❌ No negative-emission test: `blog.post_created` must NOT be emitted when the changeset is invalid; `blog.post_updated`/`post_deleted` must NOT be emitted on `:unauthorized`. No such assertion exists (the upload audit's "NOT emitted when …" pattern has no blog counterpart). | ❌ |
| 12.1.2 | ❌ The worker's `blog.associations_suggested` emission with payload `{book_ids, count}` (US-12.1.2 §6) is **not** asserted — worker_test checks persisted associations only, never the event. `blog.association_confirmed` / `blog.association_dismissed` emission by `confirm_association/2` / `dismiss_association/2` (payload `{post_id, book_id}`) have **no** test at all. | ❌ | ⚠️ blog_association_handler_test.exs — "ignores unrelated events" (`refute_enqueued`) covers one negative path. BUT no test that `associations_suggested` is skipped/empty on a failed LLM run, nor that confirm/dismiss emit nothing on `:not_found`/`:unauthorized`. | ⚠️ |
| 12.1.3 | n/a — reading posts emits no events by design (US-12.1.3 §6). Issue §5 "No events emitted by blog reading" is a low-value negative assertion left uncovered. | n/a | n/a — same. | n/a |

#### Layer 5: Background Jobs (Oban)

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | ✅ blog_association_handler_test.exs — "enqueues PostBookAssociationWorker on blog.post_published" (`assert_enqueued args: %{post_id}`), completing the publish→handler→enqueue chain (US-12.1.1 §7). | ✅ | ✅ blog_association_handler_test.exs — "ignores unrelated events" (`refute_enqueued` on `user.registered`). | ✅ |
| 12.1.2 | ✅ worker_test.exs — "associates books when LLM returns valid JSON", "returns :ok when LLM returns empty array"; worker declares `queue: :default, max_attempts: 3` (US-12.1.2 §7) via the `use Oban.Worker` macro. | ✅ | ✅ worker_test.exs — "returns :ok when post does not exist" (logs warning, no retry), "returns :ok when LLM returns invalid JSON" (no retry), "retries on LLM failure" (`{:error, :circuit_open}`). | ✅ |
| 12.1.3 | n/a — reading is synchronous, no Oban job (US-12.1.3 §7). | n/a | n/a — same. | n/a |

#### Layer 6: External Service Calls

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | n/a — write/publish flow makes no external call (US-12.1.1 §8); LLM association is async (US-12.1.2). | n/a | n/a — same. | n/a |
| 12.1.2 | ✅ worker_test.exs — drives `Stacks.AI.MockTogetherClient` (`put_response`) with a valid JSON array; worker calls `together_client().complete(prompt, max_tokens: 1024, temperature: 0.2)`. | ✅ | ⚠️ worker_test.exs — "retries on LLM failure" exercises `{:error, :circuit_open}` via the mock. BUT the real `Stacks.AI.TogetherClient` — its `:together_ai_fuse` melt/blow (3 failures in 2 min) and the `{:error, :api_key_missing}` branch (US-12.1.2 §8) — has **no** test (`together_client_test.exs` does not exist). | ⚠️ |
| 12.1.3 | n/a — reading makes no external call (US-12.1.3 §8). | n/a | n/a — same. | n/a |

#### Layer 7: Storage (R2 / Local)

| US | Happy Path | Sad Path |
|----|------------|----------|
| 12.1.1 | n/a — no storage in the write/publish flow (US-12.1.1 §9). | n/a — same. |
| 12.1.2 | n/a — associations are DB rows, no object storage (US-12.1.2 §9). | n/a — same. |
| 12.1.3 | n/a — read-only, no storage (US-12.1.3 §9). | n/a — same. |

#### Layer 8: Cache Interactions

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | n/a — CRUD does not touch a cache (US-12.1.1 §10). | n/a | n/a — same. | n/a |
| 12.1.2 | ✅ cache_invalidation_handler_test.exs — "invalidates multiple books on blog.associations_suggested with string keys" + "…with atom keys" (US-12.1.2 §10 — book-detail "My Writing" freshness). | ✅ | n/a — empty `book_ids` is a benign no-op; both key-shape variants already exercise robustness. | n/a |
| 12.1.3 | n/a — book-detail cache read reuses the generic mechanism; browsing writes no cache (US-12.1.3 §10). | n/a | n/a — same. | n/a |

#### Layer 9: dbt Model Dependencies

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | ⚠️ `stg_blog_posts.sql` exists (proto-generated) with schema.yml `not_null`+`unique` on `id`, `not_null` on `created_at`/`updated_at`; `mart_blog_activity` + `int_blog_engagement` exist; registry wires `blog.post_published`/`post_updated`/`post_deleted` → `DbtRefreshHandler`. BUT no test asserts those blog events enqueue a dbt refresh (the upload audit's `upload_dbt_test.exs` has no blog counterpart). | ⚠️ | ❌ No `accepted_values` test on `stg_blog_posts.visibility` (owner/group/platform) and no `relationships` test `user_id → stg_users.id`. Caveat: schema.yml is proto-generated by `mix proto.sync` — new tests go through the manifest/generator or a singular test under `dbt/tests/`, not a hand-edit. | ❌ |
| 12.1.2 | ✅ `stg_post_book_associations.sql` exists (proto-generated) with `not_null`+`unique` on `id`, `not_null` on `created_at`; `mart_llm_faithfulness.sql` exists for LLM-quality metrics (US-12.1.2 §11). | ✅ | ❌ No `accepted_values` on `stg_post_book_associations.source` (llm/manual) or on `visible`; no `relationships` tests `post_id → stg_blog_posts.id` / `book_id → stg_books.id`; no singular test under `dbt/tests/` references associations. Same proto-sync caveat as US-12.1.1. | ❌ |
| 12.1.3 | n/a — US-12.1.3 §11 marks dbt N/A for the read path; blog dbt coverage is accounted under 12.1.1/12.1.2 above. | n/a | n/a — same. | n/a |

#### Layer 10: Elm Frontend State Machine

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | ❌ `Page.Blog.Editor` **has zero tests** — no file in `frontend/tests/` exercises `New`/`Edit` init, `SetTitle`/`SetBody`/`SetVisibility`, `SaveDraft` → `Api.createBlogPost`/`updateBlogPost`, `SaveCompleted (Ok newId)` mode-switch, or the two-step `Publish` → `PublishCompleted` flow (US-12.1.1 §12). `Editor.elm` exists; the state machine is untested. | ❌ | ❌ No failure-state tests: `SaveCompleted (Err _)` → `saving = Failure`, `PublishCompleted (Err _)`, `PostLoaded (Err _)` in edit mode. Neither elm-test nor Playwright. | ❌ |
| 12.1.2 | ❌ `Page.Blog.Post` association Msgs (`ConfirmAssociation`/`DismissAssociation`/`AssociationActionCompleted` → reload, US-12.1.2 §12) and `Components.BookAssociations` confidence-badge thresholds (≥80 high / ≥50 medium / <50 low) are **untested**. `BlogPostCommentTest.elm` imports `Page.Blog.Post` but only covers **comment** Msgs (`CommentsLoaded`, `SubmitComment`, author badge) — US-13, not associations. `ProtoDecoderTest.elm` covers response decoders only (decoder layer, not state machine). | ❌ | ❌ No sad-path tests: `AssociationActionCompleted (Err _)` → `actionResult = Failure`, non-owner hiding of dismissed associations in the view. | ❌ |
| 12.1.3 | ❌ `Page.Blog.Archive` (`PostsLoaded (Ok/Err)`, empty state "No posts yet.", `isAuthenticated` "New Post" link) and `Page.Blog.Post` load states (`PostLoaded (Ok/Err)`, owner-only Edit link) are **untested** (US-12.1.3 §12). `ProtoDecoderTest.elm` decodes `BlogPostListResponse` but tests no page. | ❌ | ❌ No `PostsLoaded (Err _)` / `PostLoaded (Err _)` failure-message tests. | ❌ |

#### Layer 11: Operational Metrics

| US | Happy Path | Sad Path |
|----|------------|----------|
| 12.1.1 | n/a — blog CRUD counts and draft/publish ratio (US-12.1.1 §13) are derived from `event_log` rows (whose emission is tested at L4) and surfaced via the SLO gate / dashboard, not per-US telemetry firing tests. `observability_telemetry_test.exs` covers vision/fuse/budget/costs generically. | n/a — same. |
| 12.1.2 | n/a — `PostBookAssociationWorker` success/failure rates, `:together_ai_fuse` state transitions, and confirm/dismiss counts (US-12.1.2 §13) are covered by generic Oban `[:oban, :job, :stop]` telemetry + `[:stacks, :fuse, :blown/:melt]` firing tests (`observability_telemetry_test.exs`) and event counts; no blog-specific SLI is defined in `scripts/check-slo-gate.sh`. | n/a — same. |
| 12.1.3 | n/a — read counts, archive-list counts, and visibility drop-rate (US-12.1.3 §13) are dashboard concerns over `event_log` / `mart_blog_activity`, not unit-test assertions. | n/a — same. |

#### Layer 12: Performance & Usability Metrics

| US | Happy Path | Sad Path |
|----|------------|----------|
| 12.1.1 | n/a — create/update/publish latency (US-12.1.1 §14) is covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy); in-test SLA bounds are an anti-pattern under variable CI timing. | n/a — same. |
| 12.1.2 | n/a — publish→association end-to-end time and LLM call latency (US-12.1.2 §14) are SLO-gate / dashboard concerns, not unit tests. | n/a — same. |
| 12.1.3 | n/a — archive/single-post/cross-reference load times (US-12.1.3 §14) are SLO-gate concerns. | n/a — same. |

#### Layer 13: Cost Tracking

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 12.1.1 | n/a — CRUD has no external spend; the only Together-AI cost is indirect via publish and belongs to US-12.1.2. Neon/dbt compute is covered by the cost dashboard at deploy time. | n/a | n/a — same. | n/a |
| 12.1.2 | ❌ **Feature gap** — `PostBookAssociationWorker` calls `together_client().complete/2` but **never** calls `BudgetTracker.record_cost/2` (verified: no `BudgetTracker`/`record_cost` reference in the worker). The Together-AI line item is silently $0, exactly the bug class the upload audit fixed for Modal (fix #12). Per the domain rule (external LLM call → Layer 13 applies), this cell is ❌. `BudgetTracker` itself is tested generically. | ❌ | ❌ Same — no cost is recorded on the success branch, and none on the `{:error, :circuit_open}`/`:api_key_missing` branches either (should still record the attempted spend where a round-trip occurred). | ❌ |
| 12.1.3 | n/a — browsing is read-only DB compute, no external spend (US-12.1.3 §15). | n/a | n/a — same. | n/a |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline). Items marked
**BLOCKED** depend on feature code that does not yet exist.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 12.1.2 happy | Assert `GET /api/blog/posts/:id` returns the `associations` array; owner response includes `reasoning`, non-owner response omits `reasoning` and hides `visible:false` associations | `apps/core/test/stacks_web/controllers/blog_controller_test.exs` |
| 2 | L1 12.1.3 happy | Assert index ordering: owner sees `created_at desc` (incl. drafts), non-owner sees `published_at desc`; insert ≥2 posts with distinct timestamps | `apps/core/test/stacks_web/controllers/blog_controller_test.exs` |
| 3 | L2 12.1.2 sad | 401-unauthenticated tests for `PUT …/associations/:id/confirm` and `/dismiss` | `apps/core/test/stacks_web/controllers/blog_controller_test.exs` |
| 4 | L2 12.1.3 sad | Block-hiding: a post authored by a user who has blocked (or is blocked by) the viewer returns 404 / is filtered from index (`Social.blocked?/2`, US-12.1.3 §4) | `apps/core/test/stacks_web/controllers/blog_controller_test.exs` and/or `blog_test.exs` |
| 5 | L3 12.1.3 happy | Context tests for `get_post_for_viewer/2` (visible post returned) and `list_posts_for_book/2` (cross-reference JOIN returns only `visible=true` + published posts passing `Visibility.can_view?`) | `apps/core/test/stacks/blog_test.exs` |
| 6 | L3 12.1.3 sad | `get_post_for_viewer/2` returns `nil` for a non-visible / owner-only post viewed by a non-owner | `apps/core/test/stacks/blog_test.exs` |
| 7 | L4 12.1.1 happy | Extend the four "emits blog.post_*" tests to assert payload shape (`{user_id, title, visibility}` for created/updated, `{user_id, title}` for published, `{user_id}` for deleted), not just the count | `apps/core/test/stacks/blog_test.exs` |
| 8 | L4 12.1.1 sad | Negative-emission: no `blog.post_created` on invalid changeset; no `blog.post_updated`/`post_deleted` on `:unauthorized` | `apps/core/test/stacks/blog_test.exs` |
| 9 | L4 12.1.2 happy | Assert the worker emits `blog.associations_suggested` with `{book_ids, count}`; assert `confirm_association/2` emits `blog.association_confirmed` and `dismiss_association/2` emits `blog.association_dismissed` with `{post_id, book_id}` | `apps/core/test/stacks/workers/post_book_association_worker_test.exs` + `apps/core/test/stacks/blog_test.exs` |
| 10 | L4 12.1.2 sad | No `blog.associations_suggested` on a fully-failed LLM run; no confirm/dismiss event on `:not_found`/`:unauthorized` | `apps/core/test/stacks/blog_test.exs` |
| 11 | L6 12.1.2 sad | Direct `Stacks.AI.TogetherClient` test: `:together_ai_fuse` blows after 3 failures in 2 min (returns `{:error, :circuit_open}`); `{:error, :api_key_missing}` when key absent | new `apps/core/test/stacks/ai/together_client_test.exs` |
| 12 | L9 12.1.1 happy | Assert `blog.post_published`/`post_updated`/`post_deleted` each enqueue a `DbtRefreshHandler` job (pattern: `upload_dbt_test.exs`) | new `apps/core/test/stacks/blog_dbt_test.exs` or extend `blog_test.exs` |
| 13 | L9 12.1.1 sad | `accepted_values` on `stg_blog_posts.visibility` (owner/group/platform) + `relationships` `user_id → stg_users.id` — via proto-sync generator or singular test (schema.yml is proto-generated) | `dbt/tests/singular/` or `mix proto.sync` manifest |
| 14 | L9 12.1.2 sad | `accepted_values` on `stg_post_book_associations.source` (llm/manual) + `relationships` `post_id → stg_blog_posts.id`, `book_id → stg_books.id` — same proto-sync caveat | `dbt/tests/singular/` or `mix proto.sync` manifest |
| 15 | L10 12.1.1 happy | `Page.Blog.Editor` state-machine tests: New/Edit init, `SetTitle`/`SetBody`/`SetVisibility`, `SaveDraft` → correct Api call, `SaveCompleted (Ok newId)` mode-switch, two-step `Publish` → `PublishCompleted (Ok _)` | new `frontend/tests/Page/BlogEditorTest.elm` |
| 16 | L10 12.1.1 sad | `Page.Blog.Editor` failure states: `SaveCompleted (Err _)`, `PublishCompleted (Err _)`, `PostLoaded (Err _)` | same file as #15 |
| 17 | L10 12.1.2 happy | `Page.Blog.Post` association tests: `ConfirmAssociation`/`DismissAssociation` → Api call + `actionResult = Loading`, `AssociationActionCompleted (Ok _)` → reload; `Components.BookAssociations` confidence-badge thresholds (≥80 high / ≥50 medium / <50 low), owner-only Confirm/Dismiss buttons | new `frontend/tests/Page/BlogPostAssociationsTest.elm` or extend `BlogPostCommentTest.elm` |
| 18 | L10 12.1.2 sad | `AssociationActionCompleted (Err _)` → `actionResult = Failure`; non-owner view hides dismissed / shows no reasoning | same file as #17 |
| 19 | L10 12.1.3 happy | `Page.Blog.Archive` tests: `PostsLoaded (Ok _)` list render, empty state "No posts yet.", "New Post" link only when `isAuthenticated`; `Page.Blog.Post` `PostLoaded (Ok _)` + owner-only Edit link | new `frontend/tests/Page/BlogArchiveTest.elm` (+ Post) |
| 20 | L10 12.1.3 sad | `PostsLoaded (Err _)` → "Could not load posts…"; `PostLoaded (Err _)` → "Could not load post…" | same file(s) as #19 |
| 21 | E2E (framework row) | Create `e2e/tests/blog.spec.ts` (Issue §1/§2): editor flow (`/blog/new` → save draft → publish), archive list + "New Post" auth-gating, post detail with associations + confidence badges, owner Confirm/Dismiss vs non-owner view, `/blog/new` unauth → login, public archive/detail without auth, empty-archive message | new `e2e/tests/blog.spec.ts` |
| 22 | L13 12.1.2 happy+sad | **Feature gap** — instrument `PostBookAssociationWorker` to call `BudgetTracker.record_cost(:together_ai, …)` after the `complete/2` round-trip on every branch (success, circuit_open, api_key_missing), then add a firing test. **Partially blocked on feature implementation** — the call does not exist in the worker yet. | `apps/core/lib/stacks/workers/post_book_association_worker.ex` + `worker_test.exs` |
| 23 | Framework (WritingAssistant) | **BLOCKED on feature implementation (US-12.2.1).** Issue #123 §6/§7/§1 require `WritingAssistantNudgeWorker` (on-save, `Llama-3.3-70B-Instruct-Turbo`, `WritingAssistantClient`, `:writing_assistant_fuse`, debounced ≤1/10min), `WritingAssistantNudgeHandler`, `op.blog_assistant_sessions`, `consent_writing_assistant`, `MockWritingAssistantClient`, and the editor assistant-panel nudge UI + publish-gate prompt. None exist. Should be split into a new issue tracked under US-12.2.1, not implemented within #123's scope. | new issue (US-12.2.1) — Elixir worker/client/handler/migration + Elm editor panel + tests |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 3-US matrix (78 cells):

- **19 ✅ STRONG** — the server-side blog + association core is genuinely
  well covered: full CRUD context (blog_test 34), all 9 controller endpoints
  incl. 401/403/404/422 (blog_controller_test 24), the LLM worker's four
  outcome paths, the publish→enqueue handler chain, changeset validations,
  and cache invalidation on `blog.associations_suggested`.
- **10 ⚠️ shallow** — event tests assert counts not payloads; associations
  not asserted in the `GET /:id` payload; index ordering unasserted;
  `get_post_for_viewer` / `list_posts_for_book` untested; confirm/dismiss
  401 missing; block-hiding untested; `TogetherClient` fuse/api-key untested;
  blog-event→DbtRefresh enqueue untested; dbt models generic-only.
- **12 ❌ missing** — negative event-emission (2), assoc-event emission (1),
  dbt `accepted_values`/`relationships` (2), the entire Elm state-machine
  layer (6 cells: Editor, Post-associations, Archive), and Together-AI cost
  tracking (2, a feature gap).
- **37 n/a** — Python (no vision), storage, most cache, operational/
  performance metrics (SLO gate), read-path cost tracking, and the read-path
  layers of US-12.1.3 — each with an inline rationale.

**Headline findings:**
1. **Blog is partially implemented.** The post + LLM-association half is
   fully built and server-side coverage is strong; the **WritingAssistant
   nudge half (US-12.2.1) is entirely absent** — worker, client,
   `:writing_assistant_fuse`, `blog_assistant_sessions`, consent gate, and
   assistant-panel UI do not exist. Those Issue-#123 requirements are
   **blocked on feature implementation** (punch #23) and should become a
   new issue.
2. **The Elm layer is untested end to end.** `Page.Blog.Editor`,
   `Page.Blog.Archive`, and the association Msgs of `Page.Blog.Post` have
   **zero** state-machine tests (the one blog Elm file, `BlogPostCommentTest`,
   is comments-only), and **no `e2e/tests/blog*.spec.ts` exists** — every
   Playwright requirement in Issue §1/§2 is unmet.
3. **Together-AI spend is silently $0** — `PostBookAssociationWorker` never
   calls `BudgetTracker.record_cost`, the same billing bug the upload audit
   fixed for Modal (fix #12).
4. **Events are shallow** — all seven blog events are emission-counted but
   payloads are unasserted, association-event emission is untested, and there
   are no negative-emission (rollback) tests.

**Test runner totals at baseline (blog-related):** Elixir ~77 tests across 6
files (blog_test 34, blog_controller_test 24, post_test 5,
post_book_association_test 5, blog_association_handler_test 2,
post_book_association_worker_test 5, + 2 cache-handler tests), Elm 0 page
state-machine tests (comment/proto-decoder only), E2E 0, dbt generic
id/timestamp tests on 2 staging models. Punch list: **23 items**, of which #22
is partially and #23 fully blocked on feature implementation.
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires Blog context, BlogController, PostBookAssociationWorker, Together AI mock client.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
