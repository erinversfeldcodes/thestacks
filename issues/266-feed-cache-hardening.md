# Issue #266: Feed cache hardening — upsert-error handling + redundant FK index

## Summary
Two non-blocking robustness follow-ups from the #119 epic review (elixir-reviewer) on the #264 feed
cache: (1) an unhandled `{:error, %Ecto.Changeset{}}` path from a failed cache upsert can crash the
public feed endpoint / worker; (2) the proto generator emits a redundant non-unique FK index
alongside the unique one.

## User Stories
US-6.1 (Subscribe to Shelf RSS Feeds) — robustness/cleanup.

## Goal
A cache-write failure degrades gracefully (serve/return an error, not a 500/crash), and `op.feed_cache`
carries only the one index it needs.

## Wiring
Implementation-only — the `/api/feeds/...` route already exists.

## Feature-Completeness Pre-Check
n/a — the feed cache is built (#264); this hardens error paths.

## Technical Requirements
1. **Graceful upsert-error handling.** `Stacks.Feeds.render_and_cache/1` returns `{:error,
   %Ecto.Changeset{}}` when `put_cache/3` fails, and `fetch_feed/2`/`regenerate/2` propagate it — but
   their `@spec` claims only `{:error, :not_found | :not_public}`, and neither `FeedController.show`
   nor `RegenerateFeedJob.perform` has a clause for a changeset error → `CaseClauseError` (HTTP 500 /
   job crash-and-retry). Fix: either add a catch-all `{:error, _}` clause (500-with-logging for the
   controller — or better, still serve the freshly-rendered XML and just skip the cache write; a
   graceful `{:error, reason}`/retry for the worker) and widen the `@spec`s to match. Prefer
   **serving the fresh render even if the cache write fails** — the cache is an optimization, not a
   correctness dependency.
2. **Drop the redundant FK index.** The migration creates both `feed_cache_bookshelf_id_index`
   (non-unique) and `feed_cache_bookshelf_id_unique_index` (unique) on the same single column
   (`20260720152621_create_feed_cache.exs`). The unique index fully serves FK lookups + the upsert
   conflict target. The non-unique one is a proto-generator artifact (auto-emitted for a
   `references_table` override; documented in `proto/persisted.exs`). Fix: suppress the auto FK index
   when a unique index already covers the column (generator change) — or drop it in a follow-up
   migration. Prefer the generator fix so it doesn't recur for future tables.

## Reviewer Context
- The changeset-error path is **unlikely** (a bare-struct `Repo.insert` typically raises on a DB
  constraint rather than returning `{:error, changeset}`), which is why it's non-blocking — but the
  `@spec` is inaccurate today and a public endpoint should not 500 on a cache miss-fill failure.
- The generator fix is the higher-leverage option for the redundant index (benefits every future
  `references_table` table); a one-off drop migration is the tactical alternative.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1 (API) | yes | ❌ no test that a cache-write failure still serves the feed (not 500) (→ ✅) |
| 5 (Oban) | yes | ⚠️ worker error-path on cache-write failure untested (→ ✅) |
| 3 (DB/migration) | yes | ⚠️ assert `op.feed_cache` has exactly one bookshelf_id index after the fix (→ ✅) |
| others | no | n/a |

## Definition of Done
- [ ] Cache-write failure serves the fresh feed (or graceful error), no 500/crash; `@spec`s accurate — evidence: controller + worker tests
- [ ] `op.feed_cache` has a single `bookshelf_id` index (generator suppresses the redundant one, or drop migration) — evidence: migration/schema + `proto.sync --check` green
- [ ] `just verify` passes — evidence: command→output
- [ ] Test audit GREEN — evidence: table

## Dependencies
Follow-up from #119 epic (child #264). Non-blocking for the #119 PR.

## Agent Assignment
elixir-agent + database-agent (generator) + protobuf-agent (if generator change)

## Progress Notes
- 2026-07-20: Filed from #119 batched review (elixir-reviewer Findings 1 + 2).
