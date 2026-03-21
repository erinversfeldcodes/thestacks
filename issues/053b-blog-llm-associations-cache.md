# Issue #053b: Blog LLM Associations + BookDetailCache

## Summary
Build LLM-powered book association for blog posts and an ETS-backed BookDetailCache with event-driven invalidation.

## User Stories
US-12.2 — "As a user, I want my blog posts to automatically show which books they mention."
US-5.3 — "As a user, I want fast book detail loading."

## Goal
When a post is published, an Oban worker sends the post body to the vision sidecar for LLM analysis, which returns book associations with confidence scores. A BookDetailCache reduces repeated DB queries for book detail pages.

## Scope Check
- 1 Oban worker (`PostBookAssociationWorker`)
- 1 GenServer (`BookDetailCache`)
- 1 event handler (`BlogAssociationHandler`)
- Vision sidecar Python changes
- ~250 LOC

## Wiring
- [x] This issue is implementation only. Blog CRUD endpoints from #053a serve association data.

## Technical Requirements

1. **Vision sidecar `POST /associate-books`** (Python):
   - Accepts `{ post_body: string, books: [{id, title, author}] }`
   - Returns `{ associations: [{book_id, confidence, reasoning}] }`
   - Uses the LLM to determine which books from the catalogue are discussed in the post
   - New endpoint separate from existing `/associate` (which is for cover classification)

2. **`PostBookAssociationWorker`** (Oban worker):
   - Triggered by `blog.post_published` event via handler
   - Fetches post body + user's catalogue books
   - Calls vision sidecar `/associate-books`
   - Inserts `PostBookAssociation` records with confidence + reasoning
   - Emits `blog.associations_suggested` event

3. **`BlogAssociationHandler`** (event handler):
   - On `blog.post_published`: enqueue `PostBookAssociationWorker`
   - Register in Events.Registry

4. **`Stacks.Books.BookDetailCache`** (ETS GenServer):
   - `get/1` — returns cached book detail or fetches from DB
   - `invalidate/1` — removes cache entry for a book_id
   - ETS table with `{book_id, book_detail, inserted_at}` entries
   - TTL: 5 minutes (stale entries re-fetched)
   - Start under application supervision tree

5. **Cache invalidation handlers**:
   - On `book.created` / `book.cover_confirmed` / `blog.associations_suggested` → invalidate affected book_ids
   - Register in Events.Registry

## Reviewer Context
- Vision sidecar's existing `/associate` is for cover classification (edition → ISBN), NOT for post→book associations
- `PostBookAssociation` schema already has confidence, reasoning, source fields
- The `complete/2` callback on TogetherClient could be used instead of a vision sidecar endpoint if we want to avoid Python changes

## Definition of Done
- [ ] `PostBookAssociationWorker` calls vision sidecar and persists associations
- [ ] Vision sidecar `/associate-books` returns book associations with confidence
- [ ] `BookDetailCache` GenServer starts under supervision
- [ ] Cache invalidation fires for relevant events
- [ ] Cache survives GenServer crash (ETS owned by supervisor)
- [ ] Tests cover: worker, cache get/invalidate/TTL, event handlers
- [ ] `just verify` passes

## Dependencies
- Issue #053a (blog CRUD — must be complete for post_published event)

## Agent Assignment
elixir-agent + python-agent

## Progress Notes
