# Issue #159: Production — handle image.rejected in CacheInvalidationHandler

## Summary
`CacheInvalidationHandler` currently only handles `book.created`, `book.cover_confirmed`, and `blog.associations_suggested`. When an image is rejected (status → "rejected"), no cache invalidation fires. While rejection doesn't create books, it may leave stale "pending" cache entries for the upload status. This issue adds `image.rejected` handling and the corresponding test.

## User Stories
US-1.1.2, US-1.1.3

## Goal
Rejected images invalidate any cached upload-status entries so clients don't receive stale "pending" responses after rejection.

## Scope Check
- Touches 1 handler + 1 registry entry + 1 test file — well within scope.

## Wiring
- [x] Implementation only (cache behaviour, not user-facing).

## Technical Requirements

### 1. Determine what to invalidate
- Check whether there is an upload-status cache (separate from `BookDetailCache`). If upload status is read from the DB on every poll (no cache), this issue may only require a comment documenting the decision.
- If there IS an upload status cache: add `image.rejected` handling to invalidate the entry for the `aggregate_id` (upload image ID).

### 2. If cache exists — handler change
File: `apps/core/lib/stacks/books/handlers/cache_invalidation_handler.ex` (or a new `UploadCacheInvalidationHandler`)
```elixir
def handle_event(%{event_type: "image.rejected", aggregate_id: image_id}) do
  UploadStatusCache.invalidate(image_id)
  :ok
end
```

### 3. Registry entry
File: `apps/core/lib/stacks/events/registry.ex`
```elixir
"image.rejected" => [Stacks.Books.Handlers.CacheInvalidationHandler]
```

### 4. Test
File: relevant cache test file
- Populate a cache entry for an upload image.
- Emit `image.rejected` and dispatch via `SubscriberWorker`.
- Assert cache entry is gone.

## Reviewer Context
- **This is currently BLOCKED**: the feasibility assessment found that upload status polling reads from the DB directly — no upload-status cache exists. Before implementing, verify whether an upload status cache is needed or if polling is always DB-read.
- If no upload-status cache exists, this issue resolves as "no action needed — polling is DB-authoritative" and should be closed with a comment.

## Definition of Done
- [ ] Feasibility verified: does an upload-status cache exist?
- [ ] If yes: handler + registry + test implemented
- [ ] If no: issue closed with explanation, ticket for upload-status cache filed separately if needed
- [ ] `mix test` green, `mix credo --strict` clean

## Dependencies
Depends on confirming whether an upload-status cache exists.

## Agent Assignment
elixir-agent

## Progress Notes
