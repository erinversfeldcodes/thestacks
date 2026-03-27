# Runbook: Circuit Breakers — Open Circuit in Production

**Severity:** P2 (partial feature degradation — depends on which circuit is open)
**Owner:** Platform operator
**Last reviewed:** 2026-03-26

---

## Overview

All external HTTP calls are protected by `:fuse` circuit breakers installed at startup
by `Stacks.CircuitBreakers`. When a circuit is open, the relevant feature degrades
gracefully rather than accumulating failures.

| Fuse atom | Service | Threshold | Reset | Open behaviour |
|-----------|---------|-----------|-------|----------------|
| `:vision_fuse` | Modal vision service | 5 failures / 60s | 5 min | Oban vision jobs retry with backoff |
| `:together_ai_fuse` | Together AI LLM | 5 failures / 60s | 5 min | Review summaries skipped |
| `:open_library_fuse` | Open Library API | 5 failures / 60s | 5 min | Falls back to Google Books |
| `:google_books_fuse` | Google Books API | 5 failures / 60s | 5 min | ISBN lookup fails gracefully |
| `:scraper_fuse` | Rust scraper service | 3 failures / 60s | 15 min | All store scrapes skipped until reset |

---

## Symptoms

**User-visible:**
- Photo upload stalls or returns an error → `:vision_fuse` may be open
- Book review summaries missing → `:together_ai_fuse` may be open
- New book ISBN lookup fails consistently → `:open_library_fuse` or `:google_books_fuse`
- Price data not updating for any store → `:scraper_fuse` may be open

**Operator-visible (metrics dashboard / logs):**
- `[:stacks, :fuse, :blown]` telemetry event with `fuse_name` metadata
- Repeated `{:error, :circuit_open}` in Oban job error logs
- Oban queue depth growing (jobs in `retrying` or `scheduled` state)

---

## Diagnosis

### Step 1: Identify which circuit(s) are open

```bash
fly ssh console -a thestacks-core
```

```elixir
# Check all fuses at once
for name <- [:vision_fuse, :together_ai_fuse, :open_library_fuse, :google_books_fuse, :scraper_fuse] do
  IO.puts("#{name}: #{inspect(:fuse.ask(name, :sync))}")
end
```

Expected output:
```
vision_fuse: :ok
together_ai_fuse: :ok
open_library_fuse: :ok
google_books_fuse: :ok
scraper_fuse: :ok
```

Any `:blown` line identifies the affected service.

`{:error, :not_found}` means `Stacks.CircuitBreakers` failed to start — restart the app.

### Step 2: Check when the circuit blew

Search logs for the telemetry event:

```bash
fly logs -a thestacks-core | grep "stacks.fuse.blown"
```

Or query Oban for recent failures on the relevant queue:

```sql
-- Vision failures
SELECT id, attempted_at, errors
FROM oban_jobs
WHERE queue = 'vision' AND state IN ('retrying', 'discarded')
ORDER BY attempted_at DESC LIMIT 20;

-- Scraper failures
SELECT id, attempted_at, errors
FROM oban_jobs
WHERE queue = 'scraper' AND state IN ('retrying', 'discarded')
ORDER BY attempted_at DESC LIMIT 20;
```

### Step 3: Diagnose the underlying cause

| Fuse | Where to look | What to check |
|------|--------------|---------------|
| `:vision_fuse` | See [modal-outage.md](./modal-outage.md) | Modal status page, HMAC secret sync |
| `:together_ai_fuse` | Together AI status page, `fly logs` | API key valid? HTTP 401 vs 5xx |
| `:open_library_fuse` | `curl https://openlibrary.org/api/books?bibkeys=ISBN:9780743273565&format=json` | OL status, rate limits |
| `:google_books_fuse` | `curl "https://www.googleapis.com/books/v1/volumes?q=isbn:9780743273565"` | Google API key quota |
| `:scraper_fuse` | See [scraper-config-broken.md](./scraper-config-broken.md) | Rust scraper health, HMAC config |

---

## Response

### Normal case — wait for auto-reset

Circuits reset automatically after the configured window (5 or 15 minutes). If the underlying
service has recovered, **no action is required** — the circuit will close on its next probe.

Do not manually cancel Oban jobs. Jobs in `retrying` state will resume automatically.

### Manual reset (after confirming the service has recovered)

```bash
fly ssh console -a thestacks-core
```

```elixir
# Reset a specific circuit
:fuse.reset(:vision_fuse)
# or
:fuse.reset(:scraper_fuse)

# Verify it's closed
:fuse.ask(:vision_fuse, :sync)   # => :ok
```

**Only reset manually if you have confirmed the underlying service is healthy.** Resetting
a circuit while the service is still down will re-accumulate 5 failures within 60 s and
re-open it — wasting one reset cycle.

### If the circuit keeps re-opening immediately

The service is still degraded. Do not keep manually resetting. Instead:
- For vision: follow [modal-outage.md](./modal-outage.md)
- For scraper: follow [scraper-config-broken.md](./scraper-config-broken.md)
- For ISBN resolvers: check API quotas; consider temporarily disabling the enrichment worker

---

## Recovery

Circuit auto-closes when the reset timer fires AND the next `:fuse.ask` succeeds. Verify:

```elixir
iex> :fuse.ask(:vision_fuse, :sync)
:ok
```

Then confirm Oban queues are draining:

```sql
SELECT queue, state, count(*)
FROM oban_jobs
WHERE state IN ('available', 'retrying', 'executing')
GROUP BY queue, state
ORDER BY queue, state;
```

Retrying jobs will pick up and execute on their next attempt schedule.

---

## Post-Incident

- Record which fuse blew, for how long, and the root cause in the platform changelog.
- If the same fuse has blown 3+ times in 7 days: the threshold or reset config may need
  tuning, or the underlying service needs investigation. Threshold configs are in
  `apps/core/lib/stacks/circuit_breakers.ex`.
- If `:scraper_fuse` is frequently open: per-store fuses (deferred, tracked in Issue #137)
  would isolate individual store failures from the whole scraper circuit.
