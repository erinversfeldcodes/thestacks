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
iex> [:modal_vision, :together_ai, :brave_search, :open_library, :google_books]
     |> Enum.map(fn name -> {name, Fuse.ask(name)} end)

# :ok = circuit closed (requests flowing)
# :blown = circuit open (requests blocked after repeated failures)
```

A blown circuit for `brave_search` explains a backed-up `source_discovery` queue.
A blown circuit for `:open_library` would explain failed ISBN resolution jobs.

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
```elixir
# This pauses job processing for the queue (jobs accumulate but don't run)
iex> Oban.pause_queue(queue: :price_scrape)

# After fixing the issue, resume:
iex> Oban.resume_queue(queue: :price_scrape)
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
- Review Oban concurrency settings if a queue is consistently falling behind — the `concurrency` setting for that queue may need to be increased.
- Consider enabling `Oban.Web` for a visual queue monitoring UI.
