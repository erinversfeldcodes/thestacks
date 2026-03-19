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
- Metrics dashboard: "AI Budget" tracker showing > 80% of daily or monthly limit consumed
- Oban `vision` queue: jobs in `scheduled` state, not `executing` (snoozed, not failed)
- Logs: `[warn] BudgetTracker: daily limit reached, snoozing vision jobs for 1h`
- The `Stacks.AI.BudgetTracker` GenServer state shows `daily_spent_cents >= daily_limit_cents`

---

## Impact

**Broken / Degraded:**
- Photo-based book identification snoozes for up to 1 hour (then retries when budget resets)
- Vision jobs accumulate in the Oban queue in `scheduled` state

**Still working:**
- Manual ISBN entry — fully functional
- All shelving operations
- Search, prices, reviews
- All marketplace features
- Budget for review summarisation (Together AI) is tracked separately — may or may not be exhausted

---

## Diagnosis

### Step 1: Check BudgetTracker state

```bash
fly ssh console -a thestacks-core
```
```elixir
iex> Stacks.AI.BudgetTracker.status()
# Returns something like:
# %{
#   daily_spent_cents: 502,     # R5.02 spent today
#   daily_limit_cents: 500,     # R5.00 daily limit
#   monthly_spent_cents: 3750,  # R37.50 spent this month
#   monthly_limit_cents: 10_000, # R100.00 monthly limit
#   provider_stats: %{
#     modal: %{calls: 10, spent_cents: 502},
#     together_ai: %{calls: 37, spent_cents: 185}
#   },
#   reset_at: ~U[2026-03-20 00:00:00Z]  # Daily reset time
# }
```

### Step 2: Determine if this is a legitimate budget exhaustion or a runaway loop

**Legitimate:** Budget exhausted because the platform had an unusually active day. Check active user count against expected cost per upload.

Expected cost: ~R0.50–R2.50 per vision identification (Modal A10G, Qwen2.5-VL-7B). Daily limit of R5.00 = ~2–10 identifications per day.

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
-- Are there vision jobs with very high attempt counts?
SELECT id, attempt, max_attempts, args->>'image_id' as image_id, errors
FROM oban_jobs
WHERE queue = 'vision'
  AND attempt > 3
ORDER BY attempt DESC LIMIT 10;
```

High attempt counts on the same job suggest a retry loop — the job is failing and retrying, each retry calling the Modal vision service and consuming budget.

### Step 4: Identify which users are uploading heavily

```sql
-- Top uploaders today (requires joining uploaded_images with users)
SELECT u.email, count(*) as uploads
FROM uploaded_images ui
JOIN users u ON u.id = ui.user_id  -- Assumes uploaded_images has user_id; check schema
WHERE ui.uploaded_at > NOW() - INTERVAL '24 hours'
GROUP BY u.email
ORDER BY uploads DESC LIMIT 10;
```

If a single user uploaded 50 photos in one day, that explains the budget exhaustion.

---

## Response

### Immediate (do nothing if budget reset is soon)

Check when the daily budget resets:
```elixir
iex> Stacks.AI.BudgetTracker.status() |> Map.get(:reset_at)
```

If reset is within 1–2 hours: no action needed. Oban vision jobs are snoozed and will resume automatically after midnight UTC.

### If the daily limit is genuinely too low

The limit is configured in `apps/core/lib/stacks/ai/budget_tracker.ex`:

```elixir
@daily_limit_cents 500      # R5/day
@monthly_limit_cents 10_000  # R100/month
```

To raise the limit without a code deploy, if the value is runtime-configurable:

```bash
fly secrets set AI_DAILY_BUDGET_CENTS=1000 -a thestacks-core  # R10/day
fly secrets set AI_MONTHLY_BUDGET_CENTS=20000 -a thestacks-core  # R200/month
```

If the limit is compile-time only, a code change and deploy is required.

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
- Budget resets at midnight UTC (daily) or 1st of month (monthly).
- `Stacks.AI.BudgetTracker` resets its counters automatically.
- Oban vision jobs resume processing from `scheduled` state.
- No operator action required.

**Manual reset (if needed urgently — e.g., budget was raised):**
```bash
fly ssh console -a thestacks-core
```
```elixir
iex> Stacks.AI.BudgetTracker.reset_daily()
# or
iex> Stacks.AI.BudgetTracker.reset_monthly()
```

**Verify recovery:**
```elixir
iex> Stacks.AI.BudgetTracker.status()
# Should show daily_spent_cents < daily_limit_cents
```

```sql
-- Verify vision jobs are draining
SELECT state, count(*) FROM oban_jobs WHERE queue = 'vision' GROUP BY state;
-- 'scheduled' count should fall, 'completed' count should rise
```

---

## Post-Incident

- If the daily limit is consistently hit before midnight: raise the limit and update the cost model in `docs/capacity-model.md`.
- If a retry loop caused the exhaustion: add a max-cost-per-job guard in the vision worker (`Stacks.Jobs.IdentifyBookJob`) that discards the job if the image has already consumed > R2.00.
- Consider per-user upload limits in addition to global budget limits.
- Review the `Stacks.AI.BudgetTracker` warning threshold (currently 80%) — if it's not alerting early enough, lower it to 60%.
