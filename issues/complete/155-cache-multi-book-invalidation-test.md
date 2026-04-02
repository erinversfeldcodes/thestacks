# Issue #155: Test — cache invalidated per-book in multi-book resolution

## Summary
When the multi-book pipeline creates multiple books, each `book.created` event fires `CacheInvalidationHandler` which calls `BookDetailCache.invalidate(book_id)`. There is currently no test asserting this per-book invalidation behaviour.

## User Stories
US-1.1.7

## Goal
A test verifying that when N books are created via `Books.create/1` (or via the multi-book pipeline), the cache entry for each `book_id` is individually invalidated.

## Scope Check
- All items pass — test-only, ~40 LOC.

## Wiring
- [x] Implementation only.

## Technical Requirements

File: `apps/core/test/stacks/upload_cache_test.exs` (or `apps/core/test/stacks/books_test.exs` if cache is tested there)

- Find where `upload_cache_test.exs` or `book_detail_cache_test.exs` lives and follow existing patterns.
- The test should:
  1. Prime the cache with entries for two books (call `BookDetailCache.get_or_fetch(book_id, fn -> book end)` or the equivalent cache population function).
  2. Create two new books via `Stacks.Books.create/1` (which emits `book.created`) OR dispatch two `book.created` events and run `SubscriberWorker` for each.
  3. Assert that both cache entries are now stale/missing — i.e., `BookDetailCache.get(book_id)` returns `nil` or `{:miss, ...}` for each.
- Check `apps/core/lib/stacks/books/cache.ex` (or wherever `BookDetailCache` is defined) for the exact API.
- Check `apps/core/lib/stacks/books/handlers/cache_invalidation_handler.ex` for what the handler does.

## Reviewer Context
- `CacheInvalidationHandler` handles `book.created`, `book.cover_confirmed`, and `blog.associations_suggested`. It's registered in `Stacks.Events.Registry`.
- Cache is likely backed by Cachex or ETS — check the implementation before writing assertions.
- `SubscriberWorker` dispatches events synchronously via `perform_job/2` in tests.

## Definition of Done
- [ ] Test `"book.created for each book in multi-book resolution invalidates each cache entry"` passes
- [ ] `mix test` green for the relevant test file
- [ ] `mix credo --strict` clean

## Dependencies
None.

## Agent Assignment
elixir-agent

## Progress Notes
