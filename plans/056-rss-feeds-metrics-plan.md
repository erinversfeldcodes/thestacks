# Plan: Issue #056 — RSS Feeds + Metrics Dashboard Backend

## Context

Shelving context provides shelf data for feed generation. Costs context is the reference pattern for reading dbt marts. PromEx is in deps but not configured. ElixirFeedParser is available for reference but we need to GENERATE Atom XML, not parse it. No XML builder dep exists — use string interpolation for Atom (simpler, no dep).

## Key Decisions

1. **String-based Atom generation** — no XML builder dep. Atom 1.0 is a simple format, string interpolation is sufficient and avoids a dependency.
2. **Feed per public shelf** — `GET /api/feeds/:user_id/:bookshelf_name.atom`. Only platform-visible shelves generate feeds.
3. **ETag via content hash** — MD5 of the generated XML for efficient caching.
4. **Metrics read from dbt marts with fallback** — graceful `rescue` when mart views don't exist (parallel with #052c).
5. **PromEx config deferred** — add basic config now, full dashboard setup in a future issue.

## Implementation Steps

### Step 1: Create Feeds context
- `Stacks.Feeds.generate_atom/2` — accepts user_id + bookshelf_name, returns `{:ok, xml_string, etag}` or `{:error, reason}`
- Queries shelf books via `Shelving.get_bookshelf_books/2`
- Visibility check: only generate for platform-visible shelves
- Atom format: feed title, author, updated timestamp, entry per book with title, ISBN, cover URL

### Step 2: Create FeedController
- `GET /api/feeds/:user_id/:bookshelf_name.atom` — public, rate-limited
- Sets `content-type: application/atom+xml`
- ETag header from content hash
- 304 Not Modified if client sends matching `If-None-Match`

### Step 3: Create RegenerateFeedJob (Oban worker)
- Triggered by `placement.created`, `placement.moved`, `placement.removed` events
- Regenerates the affected shelf's feed and updates ETag
- Optional: cache generated XML in ETS for fast serving

### Step 4: Create Metrics context
- `Stacks.Admin.Metrics` — reads from dbt mart views
- `system_health/0` — from `marts.mart_system_health`
- `job_stats/0` — from `marts.mart_job_stats`
- `data_freshness/0` — from `marts.mart_data_freshness`
- `gdpr_compliance/0` — from `marts.mart_gdpr_compliance`
- `marketplace_activity/0` — from `marts.mart_marketplace_activity`
- All with `rescue` fallback returning empty data if mart doesn't exist

### Step 5: Create MetricsController
- `GET /api/metrics` — authenticated (owner role only)
- Returns JSON with all metric sections

### Step 6: Wire routes + PromEx basic config
- Feed: public scope with rate limiting
- Metrics: authenticated scope, owner-only
- Add basic PromEx config to config.exs

## File Inventory

### New files
- `apps/core/lib/stacks/feeds.ex`
- `apps/core/lib/stacks/admin/metrics.ex`
- `apps/core/lib/stacks_web/controllers/feed_controller.ex`
- `apps/core/lib/stacks_web/controllers/metrics_controller.ex`
- `apps/core/lib/stacks/workers/regenerate_feed_job.ex`
- `apps/core/test/stacks/feeds_test.exs`
- `apps/core/test/stacks/admin/metrics_test.exs`
- `apps/core/test/stacks_web/controllers/feed_controller_test.exs`
- `apps/core/test/stacks_web/controllers/metrics_controller_test.exs`

### Modified files
- `apps/core/lib/core_web/router.ex` — add feed + metrics routes
- `apps/core/lib/stacks/events/registry.ex` — register placement event handlers for feed regeneration
- `apps/core/config/config.exs` — PromEx basic config
