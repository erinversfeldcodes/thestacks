# Issue #154: Test — IdentifyBookJob sets age_gated visibility tier

## Summary
`IdentifyBookJob` calls `Moderation.run_pipeline/1` which calls `determine_visibility_tier/1` to inspect BISAC codes and set `visibility_tier` to `"age_gated"` or `"public"`. There is currently no job-level test asserting that the age-gated path executes correctly end-to-end through the Oban job.

## User Stories
US-1.1.4

## Goal
A test that runs `IdentifyBookJob` with a vision client returning adult BISAC codes and asserts the resulting book has `visibility_tier == "age_gated"`.

## Scope Check
- All items pass — test-only change, ~30 LOC.

## Wiring
- [x] Implementation only.

## Technical Requirements

File: `apps/core/test/stacks/workers/identify_book_job_test.exs`

- Define a `AdultBisacJobClient` (inline module in the test file) that returns a vision response including an adult BISAC subject code — one of: `FIC005000`, `FIC027000`, `FIC069000`.
  - The client must pass `is_book: true` classification, return an extractable ISBN, and include the adult BISAC code in the subjects list.
  - Check how existing mock clients like `MockVisionClient` and `RomanceBookClient` are structured — follow the same pattern.
- Run `perform_job(IdentifyBookJob, %{"image_id" => image.id})` with the mock client configured.
- After the job, fetch the created book (via `Repo.get_by(Book, ...)` or through the `UploadedImage.book_ids`) and assert `book.visibility_tier == "age_gated"`.

Key code paths to understand:
- `identify_book_job.ex` → `Moderation.run_pipeline/1` → `determine_visibility_tier/1` (in `moderation.ex`)
- `determine_visibility_tier/1` checks the BISAC codes returned by `classify_subjects/1` against a hardcoded adult list.
- The mock client controls what subjects are returned.

## Reviewer Context
- The existing `upload_pipeline_test.exs` has a `RomanceBookClient` that tests age-gating through the full pipeline test. This issue adds the equivalent at the `IdentifyBookJob` level.
- `visibility_tier` is set on the `Stacks.Books.Book` schema, not on `UploadedImage`.
- Mock clients are configured via `Application.put_env(:core, :vision_client, MockModule)` with `on_exit` cleanup.

## Definition of Done
- [ ] Test `"sets visibility_tier to age_gated when adult BISAC codes present"` in `identify_book_job_test.exs` passes
- [ ] `mix test test/stacks/workers/identify_book_job_test.exs` green
- [ ] `mix credo --strict` clean

## Dependencies
None.

## Agent Assignment
elixir-agent

## Progress Notes
