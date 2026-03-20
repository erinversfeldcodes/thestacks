# Plan: Issue #068 — Source Health Monitoring

## Context

The `op.source_health_checks` table and `Stacks.Monitoring` context exist with `change_source_health_check/2`. The generated SourceHealthCheck schema has all fields. Six enrichment workers need instrumentation. No RSSLivenessJob exists yet.

## Key Decisions

1. **Status auto-computation in context** — `record_success/2` resets consecutive_failures to 0, increments total_successes, sets status to "healthy". `record_failure/3` increments consecutive_failures + total_failures, auto-computes status: 0 failures = healthy, 3+ = degraded, 7+ = broken.
2. **Upsert by source_name** — `get_or_create/2` finds by source_name or creates with initial healthy state.
3. **RSSLivenessJob** — weekly cron, HEAD requests to all author RSS feed URLs, records success/failure.
4. **Event emission** — `source_health.recorded` after every health record write.

## Implementation Steps

### Step 1: Expand Monitoring context
- `record_success/2` — accepts source_name + source_type, upserts with: consecutive_failures=0, total_successes+1, last_success_at=now, status=healthy
- `record_failure/3` — accepts source_name + source_type + reason, upserts with: consecutive_failures+1, total_failures+1, last_failure_at=now, last_failure_reason=reason, status=auto-computed
- `get_or_create/2` — find by source_name or create with defaults
- `compute_status/1` — 0-2 failures=healthy, 3-6=degraded, 7+=broken
- Emit `source_health.recorded` event after each write

### Step 2: Instrument enrichment workers
Add `Monitoring.record_success/2` and `Monitoring.record_failure/3` calls to:
- `TriggerPriceScrapeJob` — per-store success/failure
- `FetchReviewsJob` — per-source success/failure
- `FetchAuthorRSSJob` — per-author success/failure
- `DiscoverBookstoreEventsJob` — per-store success/failure

### Step 3: Create RSSLivenessJob
- Weekly cron Oban worker
- Queries all authors with `rss_feed_url` set
- HEAD request to each URL (5s timeout)
- 200-299 → `record_success`; 404/410 → `record_failure` with reason; timeout → `record_failure`
- Does NOT remove stale feeds — just records health

### Step 4: Configuration
- Add cron: `{"0 3 * * 0", Stacks.Workers.RSSLivenessJob}` (3 AM UTC, Sundays)

## File Inventory

### New files
- `apps/core/lib/stacks/workers/rss_liveness_job.ex`
- `apps/core/test/stacks/monitoring/monitoring_test.exs` (expand existing)
- `apps/core/test/stacks/workers/rss_liveness_job_test.exs`

### Modified files
- `apps/core/lib/stacks/monitoring/monitoring.ex` — add record_success, record_failure, compute_status
- `apps/core/lib/stacks/workers/trigger_price_scrape_job.ex` — add instrumentation
- `apps/core/lib/stacks/workers/fetch_reviews_job.ex` — add instrumentation
- `apps/core/lib/stacks/workers/fetch_author_rss_job.ex` — add instrumentation
- `apps/core/lib/stacks/workers/discover_bookstore_events_job.ex` — add instrumentation
- `apps/core/config/config.exs` — add RSSLivenessJob cron
