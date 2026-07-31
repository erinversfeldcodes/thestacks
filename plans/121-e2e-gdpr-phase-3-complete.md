# Phase 3 Complete — Issue #121: Image-retention storage assertions

**Status**: APPROVED (elixir-reviewer, 0 revision cycles)
**Agent**: elixir-agent · **Reviewer**: elixir-reviewer
**Type**: test-only (no production code changed)

## What landed
New `async: false` module in `image_retention_test.exs` with 4 tests:
- `Storage.delete_image/1` invoked once per expired image and once per stuck image — via a test-local `RecordingStorage` (`delete/1` → `send(self(), {:storage_delete, key})`; works because `delete_storage_objects/1` runs synchronously in the test process); `assert_received` per path + `refute_received` catches extras/dupes.
- Storage-failure resilience (both expired + stuck): a `FailingStorage` (`delete/1 → {:error, :simulated_storage_outage}`) → cleanup logs the `image_retention.ex:148` warning AND still deletes the DB record (`Repo.get(UploadedImage, id) == nil`).
- Storage impl swapped via `Application.put_env(:core, :storage, …)` in `setup`, restored to `Stacks.Storage.Mock` in `on_exit`.

## Gates
- 2A-iv Reception: DoD table built independently — §7/§8 items ✅; assertions non-vacuous.
- 2B-i Regression: 206 tests, 0 failures (GDPR + audit + workers).
- 2B-ii Spec Coverage: §7/§8 storage-call + storage-failure — covered.
- 2B-iia Fresh-DB: skipped (test-only, no migrations).
- 2B-iii Deploy+E2E: skipped (test-only, no deployed code).
- 2C Review: elixir-reviewer → **APPROVED** first pass (3 non-blocking notes; no changes required).

## DoD Evidence
| DoD item (§7/§8) | Impl file:line | Test | Status |
|---|---|---|---|
| Storage.delete_image invoked per expired/stuck | `image_retention.ex:143` | `image_retention_test.exs` (recording spy) | ✅ |
| Storage-failure → warning + DB record deleted | `image_retention.ex:148` + `Repo.delete_all` | `image_retention_test.exs` (failing spy) | ✅ |

## Reviewer non-blocking notes (future)
- `on_exit` could capture/restore the original `:storage` value rather than hardcoding `Storage.Mock` (functionally equivalent today).
- A mixed-row case (path + nil/"") would additionally lock the `is_binary(path) and path != ""` guard in `delete_storage_objects/1`.
