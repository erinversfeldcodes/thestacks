# Runbook: Oban Queue Backlog

**Severity:** P2 (data freshness degrading — platform functional but enrichment stale)
**Owner:** Platform operator
**Last reviewed:** 2026-03-19

---

## Symptoms

**User sees:**
- Book prices are stale (last updated days ago rather than hours)
- Review summaries not refreshing
- Author info not updating
- Metrics dashboard shows "data freshness" gauges in yellow/red
- dbt mart data is stale (community wear states not updating on Looking for a Home)

**Operator sees:**
- Metrics dashboard: Oban queue depth chart trending upward over time
- `oban_jobs` table: large count of `available` state jobs accumulating
- `oban_jobs` table: high count of `retrying` or `discarded` jobs in specific queues
- Logs: repeated circuit breaker trip events for external services (Brave, review scrapers, etc.)

---

## Impact

**Broken / Degraded:**
- Data freshness: prices, reviews, author info, events — all enrichment
- dbt refresh: `mart_community_read_count` and other marts may be stale
- New book enrichment may be delayed (price/review jobs not running)

**Still working:**
- All read operations (shelves, search, book detail)
- User actions (shelving, moving, upload, manual ISBN entry)
- Authentication and settings
- Marketplace (but new listings may not get enrichment quickly)

---

## Diagnosis

### Step 1: Check queue depth by queue

```sql
SELECT queue, state, count(*)
FROM oban_jobs
GROUP BY queue, state
ORDER BY queue, state;
```

Healthy state: `available` count per queue should be < 50 at any given time. A growing `available` count indicates jobs are being enqueued faster than they're being processed.

### Step 2: Check for discarded (permanently failed) jobs

```sql
SELECT queue, worker, count(*), max(attempted_at) as last_attempt
FROM oban_jobs
WHERE state = 'discarded'
GROUP BY queue, worker
ORDER BY count(*) DESC;
```

Discarded jobs have exceeded their maximum retry count. These indicate a systematic failure in a specific worker.

### Step 3: Inspect specific failed jobs

```sql
-- See the actual error messages
SELECT id, worker, args, attempted_at, errors
FROM oban_jobs
WHERE state IN ('retrying', 'discarded')
  AND queue = '<queue_name>'
ORDER BY attempted_at DESC
LIMIT 10;
```

The `errors` JSONB column contains the exception and stacktrace for each attempt.

### Step 4: Check circuit breakers

```bash
fly ssh console -a thestacks-core
```
```elixir
# Check all circuit breaker states
iex> [:vision_fuse, :together_ai_fuse, :brave_fuse, :open_library_fuse, :google_books_fuse, :scraper_fuse, :searxng_fuse, :r2_fuse]
     |> Enum.map(fn name -> {name, :fuse.ask(name, :sync)} end)

# :ok = circuit closed (requests flowing)
# :blown = circuit open (requests blocked after repeated failures)
```

See `docs/runbooks/circuit-breakers.md` for the full fuse registry.

A blown `:brave_fuse` explains failed `Stacks.Workers.DiscoverAuthorSourcesJob` runs on the `default` queue.
A blown `:open_library_fuse` or `:google_books_fuse` would explain failed ISBN resolution in `Stacks.Workers.IdentifyBookJob` (`vision` queue) and `Stacks.Workers.EnrichBookJob` (`default` queue).
A blown `:vision_fuse` backs up the `vision` queue — see `docs/runbooks/modal-outage.md`.
A blown `:scraper_fuse` backs up the `scraper` queue (`Stacks.Workers.TriggerPriceScrapeJob`).

### Step 5: Check if the backlog is growing or stable

```sql
-- Run this query twice, 5 minutes apart. Compare the counts.
SELECT queue, count(*) as available_jobs
FROM oban_jobs
WHERE state = 'available'
GROUP BY queue;
```

If the count is growing: something is enqueuing jobs faster than they process (a loop or a misconfigured schedule).
If the count is stable: the system is catching up at the same rate jobs arrive — may just need time.
If the count is falling: the system is recovering on its own — monitor but don't intervene.

### Step 6: Check dbt refresh specifically

```sql
-- Check the dbt_refresh queue specifically
SELECT state, count(*), max(attempted_at)
FROM oban_jobs
WHERE queue = 'dbt_refresh'
GROUP BY state;

-- Check the most recent dbt job errors
SELECT id, errors, attempted_at
FROM oban_jobs
WHERE queue = 'dbt_refresh' AND state IN ('retrying', 'discarded')
ORDER BY attempted_at DESC LIMIT 5;
```

A stalled dbt_refresh queue means `wh` schema marts are not updating — community wear, enrichment gap models, etc. will be stale.

---

## Response

### If circuit breakers are blown (most common cause)

Circuit breakers trip after 5 failures in 60 seconds and reset every 5 minutes. The system self-heals if the external service recovers.

**Do:** Wait 5–10 minutes and check if the blown circuit has reset.

**If circuit does not reset:** The external service is still failing. Check the service's status page:
- Brave Search: [https://status.brave.com](https://status.brave.com)
- Open Library: Check [https://openstatus.dev](https://openstatus.dev) or test `https://openlibrary.org/api/books?bibkeys=ISBN:9780441172719&format=json`

### If a specific worker is discarding jobs systematically

The worker has a bug or the external API it calls has changed.

```bash
fly ssh console -a thestacks-core
```
```elixir
# Re-run a single discarded job to see the live error
iex> Oban.retry_job(job_id)
# Or use Oban.Web if installed
```

If the error is a parsing failure (external API changed response format): this requires a code fix and deploy.

### If the dbt_refresh queue is backed up or failing

```bash
fly ssh console -a thestacks-core
```
```elixir
# Trigger a manual dbt run to verify dbt itself is working
iex> System.cmd("dbt", ["run", "--target", "prod"], cd: "/app/dbt")
# If dbt exits non-zero: check dbt logs for SQL errors
```

A dbt failure does not block the operational platform — it only means warehouse models are stale.

### If queue depth is growing faster than it's draining

This indicates a job scheduling loop — a job is enqueuing itself recursively or a cron schedule is too aggressive.

```sql
-- Find jobs being enqueued most rapidly
SELECT worker, count(*), max(inserted_at), min(inserted_at)
FROM oban_jobs
WHERE state = 'available'
  AND inserted_at > NOW() - INTERVAL '1 hour'
GROUP BY worker
ORDER BY count(*) DESC;
```

If one worker dominates: identify the enqueue logic and check for a scheduling loop. The fix requires a code change.

**Emergency: pause a specific queue**

The configured queues are `default` (10), `events` (20), `vision` (60), `scraper` (5),
`notifications` (3), and `dbt_refresh` (1) — see `apps/core/config/config.exs`.

```elixir
# This pauses job processing for the queue (jobs accumulate but don't run)
iex> Oban.pause_queue(queue: :scraper)

# After fixing the issue, resume:
iex> Oban.resume_queue(queue: :scraper)

# To cancel or retry an individual job by id:
iex> Oban.cancel_job(job_id)
iex> Oban.retry_job(job_id)
```

---

## Recovery

**Self-healing (most common):**
- External service recovers → circuit breaker resets → jobs drain naturally.
- No operator intervention needed beyond monitoring.

**After manual intervention:**
```sql
-- Verify queue is draining
SELECT queue, state, count(*) FROM oban_jobs GROUP BY queue, state ORDER BY queue;
-- Watch the 'available' count fall and 'completed' count rise
```

**Verify data freshness recovery:**
- Metrics dashboard: data freshness gauges should return to green within 1–2 refresh cycles.
- Check the `stale_after` field on a sample of `price_snapshots`:

```sql
SELECT max(scraped_at) as last_scrape, count(*) as total
FROM price_snapshots
WHERE scraped_at > NOW() - INTERVAL '24 hours';
```

---

## Post-Incident

- If a specific worker is repeatedly discarding jobs, file an issue for the underlying cause.
- If circuit breakers are tripping frequently for an external service: consider whether that service is reliable enough to remain in the pipeline, or if a fallback/alternative should be implemented.
- Review Oban concurrency settings if a queue is consistently falling behind — the `concurrency` setting for that queue may need to be increased in `apps/core/config/config.exs`.
- Consider enabling `Oban.Web` for a visual queue monitoring UI.

---

## See also

- [ADR-002: Oban as Event Bus Instead of Kafka or RabbitMQ](../decisions/002-oban-over-kafka.md) — rationale for Oban being the only message bus.
- [Runbook: Modal vision outage](modal-outage.md) — when the `vision` queue specifically is backing up.
- [Runbook: Circuit breakers](circuit-breakers.md) — full fuse registry and probe-based recovery semantics.
- `apps/core/lib/stacks/workers/` — all worker modules. The Oban repo is `Core.ObanRepo` (shares the database with `Core.Repo`); see `apps/core/lib/core/oban_repo.ex`.
