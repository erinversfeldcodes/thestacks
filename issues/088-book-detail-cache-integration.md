# Issue #088: BookDetailCache Integration

## Summary
Wire BookDetailCache into BookController.show for actual cache hits. The cache exists (#053b) but no controller uses it.

## Goal
Book detail page loads should hit the ETS cache when available, falling back to DB on miss. Cache is invalidated by events (book.created, book.cover_confirmed, blog.associations_suggested).

## Scope Check
- Modify BookController.show to check cache before DB
- Add cache put after DB fetch
- ~30 LOC

## Technical Requirements
- `BookController.show` checks `BookDetailCache.get(id)` first
- On miss, fetch from DB, call `BookDetailCache.put(id, data)`
- Ensure cached data has the same shape as the DB-fetched data
- Consider what fields to cache (book + editions + author + placements?)

## Definition of Done
- [ ] BookController.show uses cache
- [ ] Cache miss falls back to DB and populates cache
- [ ] Existing tests pass
- [ ] `just verify` passes

## Agent Assignment
elixir-agent
