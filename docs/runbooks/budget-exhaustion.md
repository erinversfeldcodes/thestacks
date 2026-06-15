# Runbook: AI Budget Exhaustion

**Severity:** P2 (photo upload degraded — manual ISBN entry functional)
**Owner:** Platform operator
**Last reviewed:** 2026-03-19

---

## Symptoms

**User sees:**
- Photo upload stalls or returns "Our image recognition is temporarily unavailable — please try manual ISBN entry"
- Manual ISBN entry continues to work normally
- No other platform features are affected

**Operator sees:**
- Metrics dashboard: cost dashboard showing daily or monthly Modal spend at/over the configured cap
- Oban `vision` queue: `IdentifyBookJob` jobs failing with `{:error, :daily_limit_exceeded}` or `{:error, :monthly_limit_exceeded}` and retrying (up to `max_attempts: 3`)
- Telemetry event `[:stacks, :budget, :limit_exceeded]` firing with `%{type: :daily | :monthly}`
- The `Stacks.AI.BudgetTracker` GenServer state shows `daily_total_cents >= daily_limit_cents` (config) or `monthly_total_cents >= monthly_limit_cents`
- If the cap was raised on Modal's side and *Modal itself* has disabled the workspace for non-payment or quota: vision HTTP calls return `404` with a body like `modal-http: workspace <name> is disabled` (see [`modal-outage.md`](modal-outage.md) — recovery is the same as a Modal outage)

---

## Impact

**Broken / Degraded:**
- Photo-based book identification fails fast (no Modal call is made) — `Stacks.AI.Client.call_vision/2` short-circuits on `BudgetTracker.check_budget(:modal)` before the HTTP request
- `IdentifyBookJob` jobs accumulate `retryable` state until they exhaust `max_attempts: 3`, then sit in `discarded`

**Still working:**
- Manual ISBN entry — fully functional
- All shelving operations
- Search, prices, reviews
- All marketplace features
- Together AI summarisation budget is tracked under a separate provider key (`:together_ai`) in the same tracker — may or may not be exhausted

---

## Diagnosis

### Step 1: Check BudgetTracker state

```bash
fly ssh console -a thestacks-core
```
```elixir
iex> Stacks.AI.BudgetTracker.current_state()
# Returns:
# %{
#   daily_total_cents: 502,     # R5.02 spent today
#   monthly_total_cents: 3750,  # R37.50 spent this month
#   providers: %{
#     "modal" => 502,
#     "together_ai" => 185
#   }
# }

# Compare against configured limits (config :core, :ai_budget in apps/core/config/config.exs):
iex> Application.get_env(:core, :ai_budget)
# [daily_limit_cents: 500, monthly_limit_cents: 5_000]

# Confirm the tracker actually says "exceeded" for Modal:
iex> Stacks.AI.BudgetTracker.check_budget(:modal)
# {:error, :daily_limit_exceeded} | {:error, :monthly_limit_exceeded} | :ok
```

Note: `current_state/0` does not expose a reset time. The daily counter resets at the next midnight UTC tick (`schedule_midnight_reset/0`); the monthly counter is not auto-reset in code and rolls over only via deploy/restart.

### Step 2: Determine if this is a legitimate budget exhaustion or a runaway loop

**Legitimate:** Budget exhausted because the platform had an unusually active day. Check active user count against expected cost per upload.

Per [ADR-001](../decisions/001-modal-over-together-ai.md) (partially superseded by [ADR-015](../decisions/015-vision-service-architecture.md)) the caps are R5/day and R50/month. Expected cost per vision identification is in the range of cents on the current H100 + AWQ-quantized vLLM v1 setup (see ADR-015) — well under the per-call cost assumed when ADR-001 was written. The daily cap of R5 still represents a usage spike if hit.

If the daily limit is too low for normal usage, the limit needs to be raised (see Response section).

**Runaway loop:** Budget exhausted far faster than expected (minutes, not hours). Check for:

```sql
-- Are vision jobs being enqueued far more often than expected?
SELECT count(*), min(inserted_at), max(inserted_at)
FROM oban_jobs
WHERE queue = 'vision'
  AND inserted_at > NOW() - INTERVAL '1 hour';
```

A runaway loop would show hundreds of vision jobs inserted in a short window.

### Step 3: Check for retry loop specifically

```sql
-- Are there vision jobs near the attempt ceiling?
-- IdentifyBookJob is configured with `max_attempts: 3`.
SELECT id, attempt, max_attempts, args->>'image_id' as image_id, errors
FROM oban_jobs
WHERE queue = 'vision'
  AND attempt >= 2
ORDER BY attempt DESC LIMIT 10;
```

High attempt counts on the same job suggest a retry loop — the job is failing and retrying, and each retry that actually reaches Modal (i.e. budget was OK at the time) consumes another R0.x of spend. Note that the budget gate in `Stacks.AI.Client.call_vision/2` short-circuits *before* the HTTP call, so once the cap is hit the retries are free; the damage was done by retries that ran *before* the cap was reached.

### Step 4: Identify which users are uploading heavily

```sql
-- Top uploaders today
SELECT u.email, count(*) as uploads
FROM op.uploaded_images ui
JOIN op.users u ON u.id = ui.user_id
WHERE ui.uploaded_at > NOW() - INTERVAL '24 hours'
GROUP BY u.email
ORDER BY uploads DESC LIMIT 10;
```

If a single user uploaded 50 photos in one day, that explains the budget exhaustion.

---

## Response

### Immediate (do nothing if daily reset is soon)

If it's within 1–2 hours of midnight UTC: no action needed. The `BudgetTracker.handle_info(:reset_daily, …)` callback zeroes `daily_total_cents` and the per-provider map at the next scheduled tick, and `IdentifyBookJob` retries will start succeeding again on their own. Discarded jobs (those that already burnt `max_attempts: 3`) will not be re-run automatically — see Recovery.

### If the daily/monthly limit is genuinely too low

Limits are configured in `apps/core/config/config.exs`:

```elixir
config :core, :ai_budget,
  daily_limit_cents: 500,    # R5/day  (per ADR-001)
  monthly_limit_cents: 5_000  # R50/month (per ADR-001)
```

There is no runtime override (no `fly secrets` env var consulted by `BudgetTracker.get_limit/2`). Raising the cap requires editing config and redeploying. If you also need to raise Modal's own workspace cap, do that in the Modal dashboard first — otherwise vision calls will start returning `404 modal-http: workspace … is disabled` once Elixir-side spend exceeds whatever Modal is willing to bill.

### If a retry loop is consuming budget

```bash
fly ssh console -a thestacks-core
```
```elixir
# Pause the vision queue immediately to stop further spend
iex> Oban.pause_queue(queue: :vision)
```

This stops vision jobs from executing (they accumulate as `available` but don't run). No further budget is consumed.

Identify the root cause (typically a bad image that causes the vision service to return an error which triggers retry):

```sql
SELECT id, args->>'image_id', errors FROM oban_jobs
WHERE queue = 'vision' AND attempt > 2
ORDER BY attempt DESC;
```

Fix the underlying bug, deploy, then resume the queue:
```elixir
iex> Oban.resume_queue(queue: :vision)
```

### If a single user is exploiting the upload endpoint

If one user uploaded an abnormal number of photos, check the rate limiter configuration:

```elixir
# In rate_limiter.ex or plug config
# POST /api/upload/identify is rate-limited to 10 requests/min per user
```

If the rate limiter is working correctly, the user may have uploaded across multiple sessions or the rate limit is too permissive.

Consider temporarily blocking the specific user's upload access while investigating.

---

## Recovery

**Automatic (most common):**
- The daily counter resets at the next midnight UTC tick scheduled by `BudgetTracker.schedule_midnight_reset/0`.
- The monthly counter does **not** auto-reset in code — it rolls over on the next deploy/restart (the GenServer starts with `monthly_total_cents: 0`). If you genuinely hit the monthly cap and cannot wait, you'll need to bounce the app.
- Oban `vision` jobs that are still `retryable` will then make progress on the next attempt; jobs already in `discarded` need to be re-enqueued manually.

**Manual reset (no public reset function — restart the process):**

There is no `reset_daily/0` or `reset_monthly/0` on `BudgetTracker`. To force a reset:

```bash
fly ssh console -a thestacks-core
```
```elixir
# Restart the GenServer — the supervisor will bring it back up with zeroed state.
iex> Process.exit(Process.whereis(Stacks.AI.BudgetTracker), :kill)
iex> Stacks.AI.BudgetTracker.current_state()
# %{daily_total_cents: 0, monthly_total_cents: 0, providers: %{}}
```

(Or `fly apps restart thestacks-core` if you'd rather just bounce the whole release.)

**Verify recovery:**
```elixir
iex> Stacks.AI.BudgetTracker.check_budget(:modal)
# :ok
iex> Stacks.AI.BudgetTracker.current_state()
# daily_total_cents < daily_limit_cents
```

```sql
-- Verify vision jobs are draining
SELECT state, count(*) FROM oban_jobs WHERE queue = 'vision' GROUP BY state;
-- 'retryable' count should fall, 'completed' count should rise
```

---

## Post-Incident

- If the daily limit is consistently hit before midnight: raise the limit in `apps/core/config/config.exs` (and on the Modal dashboard) and update the cost model in [`../capacity-model.md`](../capacity-model.md).
- If a retry loop caused the exhaustion: add a max-cost-per-job guard in `Stacks.Workers.IdentifyBookJob` that discards the job once an image has already consumed more than a configured cents budget.
- Consider per-user upload limits in addition to global budget limits (the existing `Stacks_web.Plugs.RateLimiter` is per-endpoint, not per-cost).
- `Stacks.AI.BudgetTracker` does not currently emit a warning threshold telemetry event — only `[:stacks, :budget, :limit_exceeded]` at 100%. If we want earlier warning, add a `[:stacks, :budget, :threshold_crossed]` event around 80% in `handle_cast({:record_cost, …})`.

## Cross-references

- [`docs/decisions/001-modal-over-together-ai.md`](../decisions/001-modal-over-together-ai.md) — origin of the R5/R50 caps (partially superseded by ADR-015 for vision infra, but the budget envelope still applies).
- [`docs/decisions/015-vision-service-architecture.md`](../decisions/015-vision-service-architecture.md) — current vision service (H100, AWQ vLLM v1, `/analyze`).
- [`docs/runbooks/modal-outage.md`](modal-outage.md) — when Modal returns 5xx/timeouts or a `modal-http: workspace … is disabled` 404, recovery follows the Modal outage playbook, not this one.
- [`docs/runbooks/vision-hallucination.md`](vision-hallucination.md) — sibling runbook for bad VLM output rather than absent VLM output.
