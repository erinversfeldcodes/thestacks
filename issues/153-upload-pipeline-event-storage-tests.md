# Issue #153: Tests — upload pipeline event suppression and storage guarantees

## Summary
Three test gaps in the upload pipeline's event and storage behaviour: verifying that `image.submitted` is suppressed on storage failure, that `books.edition_merged` fires on a format merge, and that `storage_path` is preserved (not cleared) when an image is rejected.

## User Stories
US-1.1.1, US-1.1.2, US-1.1.3, US-1.1.8

## Goal
Every meaningful side-effect in the upload pipeline is asserted by at least one test. After this issue, three specific guarantees are canonised in the test suite.

## Scope Check
- [ ] This issue touches more than 3 controllers? No — test-only.
- [ ] This issue adds more than 2 new endpoints? No.
- [ ] This issue exceeds ~300 lines of production code? No — tests only.
- [ ] This issue combines unrelated concerns? No — all three relate to pipeline side-effects.

## Wiring
- [x] This issue is implementation only. No wiring needed.

## Technical Requirements

### Test 1 — L4: upload failure suppresses `image.submitted` (upload_pipeline_test.exs or identify_book_job_test.exs)
- `Books.store_upload/2` emits `image.submitted` AFTER successful storage write. On storage failure it returns `{:error, reason}` before the event is emitted.
- Mock storage to return `{:error, :storage_unavailable}` and assert no `image.submitted` event is in `event_log`.
- Use `events_of_type("image.submitted")` helper and assert `== []`.

### Test 2 — L4: `books.edition_merged` event fires on merge (books_test.exs or upload_pipeline_test.exs)
- `Books.merge_edition/2` calls `emit_or_classify_edition/3` which emits `books.edition_merged` on success.
- Write a test that calls `merge_edition/2` (or goes through the full pipeline) and asserts an event of type `"books.edition_merged"` exists in `event_log` with correct `aggregate_id`.

### Test 3 — L7: `storage_path` preserved after rejection (upload_dbt_test.exs or identify_book_job_test.exs)
- `IdentifyBookJob.mark_rejected/2` updates `status` and `rejection_reason` but does NOT clear `storage_path`.
- After running the job with a `NotABookClient` or `NoIsbnClient`, re-fetch the `UploadedImage` and assert `updated.storage_path != nil` and `updated.storage_path == original_storage_path`.

## Reviewer Context
- `events_of_type/1` is a test helper in `upload_pipeline_test.exs` that queries `event_log` for events of a given type.
- Storage is mocked via `Application.put_env(:core, :storage_client, MockStorageClient)` — check `upload_pipeline_test.exs` setup for the existing pattern.
- `mark_rejected/2` is in `apps/core/lib/stacks/workers/identify_book_job.ex`.

## Definition of Done
- [ ] Test 1: `upload failure (storage error) does not emit image.submitted event` passes
- [ ] Test 2: `merge_edition/2 emits books.edition_merged event` passes
- [ ] Test 3: `storage_path is preserved on rejection` passes
- [ ] `mix test` green, `mix credo --strict` clean

## Dependencies
None — all production code already supports these scenarios.

## Agent Assignment
elixir-agent

## Progress Notes
