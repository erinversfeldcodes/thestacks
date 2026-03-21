# Issue #052b: DbtRefreshJob — Event-Triggered + Cron Refresh

## Summary
Build the Oban worker that triggers selective dbt model rebuilds based on emitted events, with a daily cron catch-all for full refresh.

## User Stories
N/A — data engineering infrastructure.

## Goal
When enrichment events fire (e.g., `enrichment.prices_scraped`), only the affected dbt models are rebuilt. A daily cron catch-all ensures nothing falls through the cracks.

## Scope Check
- 1 Oban worker (`DbtRefreshJob`)
- 1 event handler (`DbtRefreshHandler`)
- Event registry additions
- ~200 LOC

## Wiring
- [x] This issue is implementation only.

## Technical Requirements

1. **`Stacks.Workers.DbtRefreshJob`** (Oban worker):
   - Queue: `:dbt_refresh` (concurrency 1 — only one dbt run at a time)
   - Args: `%{models: ["mart_book_prices", "int_price_trends"]}` for selective, `%{full: true}` for catch-all
   - Shells out to `dbt run --select <models>` for selective
   - Shells out to `dbt run` for full
   - Job uniqueness: coalesce rapid-fire events within 5-minute window (`unique: [period: 300]`)

2. **Event-to-model mapping** (`@model_mapping` module attribute):
   ```
   "enrichment.prices_scraped" => ["int_price_trends", "mart_book_prices"]
   "enrichment.reviews_scraped" => ["int_review_sentiment", "mart_book_reviews"]
   "enrichment.author_updated" => ["int_author_activity"]
   "enrichment.events_discovered" => ["int_event_matches"]
   "source_health.recorded" => ["mart_system_health"]
   "placement.created" => ["mart_community_read_count", "mart_platform_searchable"]
   "placement.moved" => ["mart_community_read_count"]
   ```

3. **`Stacks.Workers.DbtRefreshHandler`** (event handler):
   - Implements `Stacks.Events.Handler`
   - Looks up event_type in `@model_mapping`
   - Enqueues `DbtRefreshJob` with affected models
   - Register in Events.Registry for all mapped event types

4. **Cron**: `{"0 5 * * *", Stacks.Workers.DbtRefreshJob, args: %{full: true}}` (5 AM UTC daily)

5. **Queue config**: Add `:dbt_refresh` queue with concurrency 1

## Reviewer Context
- dbt must be available on PATH for `System.cmd("dbt", ...)` to work
- In test, mock the dbt command or skip the shell-out
- Job uniqueness prevents rebuilding the same models multiple times within 5 minutes

## Definition of Done
- [ ] `DbtRefreshJob` runs selective `dbt run --select` for event-triggered rebuilds
- [ ] Full `dbt run` works for daily catch-all
- [ ] Event handler registered for all enrichment events
- [ ] Job uniqueness coalesces rapid-fire events
- [ ] Tests cover selective refresh, full refresh, event mapping
- [ ] `just verify` passes

## Dependencies
- Issue #052a (dbt models must exist for selective refresh to target)

## Agent Assignment
elixir-agent

## Progress Notes
