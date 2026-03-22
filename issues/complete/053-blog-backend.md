# Issue #053: Blog Backend — CRUD, LLM Associations, BookDetailCache

## Summary
Build the blog context: post CRUD with visibility ceiling enforcement, LLM-powered book associations via the vision service `/associate` endpoint, and the ETS-backed BookDetailCache with event-driven invalidation.

## User Stories
US-12.1.1 (write blog post), US-12.1.2 (LLM book associations), US-12.1.3 (browse another user's blog), US-1.4.1 (book detail — "My Writing" section)

## Goal
Users can write, publish, and manage blog posts with visibility controls. After publishing, an LLM associates the post with books from the user's collection. The book detail overlay shows linked writing. The BookDetailCache eliminates redundant DB joins for the detail read path.

## Technical Requirements

**`Stacks.Blog` context:**
- `create_post/2`, `update_post/2`, `publish_post/1`, `delete_post/1`
- `get_post/2` — routes through `resolve_visibility/2` (Issue #047)
- `list_user_posts/2` — filtered by viewer's visibility level
- Visibility ceiling: post visibility ≤ profile visibility. Enforced on write via `Visibility.validate_visibility_ceiling/3`.
- Body stored as Markdown. Rendered to HTML in Elm frontend.

**`Stacks.Blog.BookAssociations`:**
- `associate_manually/3` — user links a book to a post
- `confirm_suggestion/2`, `dismiss_suggestion/2` — user reviews LLM suggestions
- Top 3 associations by confidence score surfaced on post by default

**`Stacks.Workers.PostBookAssociationWorker` (Oban):**
- Triggered by `blog.post_published` event
- Calls vision service `POST /associate` with post body + user's book catalogue
- Stores results in `post_book_associations` with confidence score + reasoning
- Fires `blog.associations_suggested` event
- Graceful fallback: if LLM fails after retries, post remains published with no associations

**Vision service — `POST /associate` endpoint:**
- Accept `{ post_body, books: [{id, title, author, description, subjects}] }`
- Return `{ associations: [{book_id, confidence, reasoning}] }`
- LLM instructed to return only books from provided catalogue (no hallucinated ISBNs)
- Add to `apps/vision/app/main.py` (currently a stub)

**`Stacks.Books.BookDetailCache` (ETS GenServer):**
- ETS table keyed by `{user_id, book_id}`
- On cache miss: `Books.get_book_detail/1` performs full join, populates cache
- On cache hit: microsecond ETS lookup
- Event-driven invalidation:
  - `blog.post_published` / `blog.associations_updated` → invalidate `(user_id, book_id)` for all associated books
  - `placement.updated` → invalidate `(user_id, book_id)`
  - `price_snapshot.created` → invalidate ALL entries for `book_id`
- Supervised under application supervisor. Crash → restart with empty cache; first miss repopulates.

**Events emitted:**
- `blog.post_published`, `blog.post_updated`, `blog.associations_suggested`

**dbt models:**
- `stg_blog_posts`, `stg_post_book_associations` (from Issue #044)
- `int_blog_engagement`, `mart_blog_activity` (from Issue #052, or create here if #052 not yet done)

## Definition of Done
- [ ] Blog post CRUD works with visibility ceiling enforcement
- [ ] `PostBookAssociationWorker` fires after publish; stores suggestions
- [ ] Manual book-tagging on posts works
- [ ] Vision service `/associate` endpoint returns book associations
- [ ] `BookDetailCache` starts under supervision
- [ ] Cache invalidation fires correctly for all 3 event types
- [ ] Cache survives GenServer crash (supervisor restarts with empty cache)
- [ ] Book detail API response includes "My Writing" section
- [ ] `mix test` passes
- [ ] `ruff check` passes on vision service changes

## Dependencies
Issue #047 (visibility — blog posts have visibility controls), Issue #043 (blog tables)

## Agent Assignment
elixir-agent + python-agent

## Progress Notes
