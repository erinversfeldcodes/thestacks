# Runbook: Modal Vision Service — Outage

**Severity:** P2 (partial feature degradation — manual ISBN entry remains functional)
**Owner:** Platform operator
**Last reviewed:** 2026-03-19

---

## Symptoms

**User sees:**
- Photo upload stalls on "Identifying your book..." with no progress after 60 seconds
- Upload eventually fails with a generic error message
- Manual ISBN entry (the fallback path) continues to work normally

**Operator sees:**
- Oban `vision` queue depth growing in `oban_jobs` table
- Jobs in `scheduled` or `retrying` state with `Stacks.AI.Client` errors in logs
- Circuit breaker `:vision_service` may be blown — check `Fuse.status(:vision_service)`
- Phoenix logs: `[error] Vision service unreachable: connection refused / timeout`
- Metrics dashboard: identification success rate dropping toward 0%

---

## Impact

**Broken:**
- Photo-based book identification (`POST /api/upload/identify`)
- Bulk photo upload flow

**Still working:**
- All other platform features
- Manual ISBN entry (`ManualISBNEntry` variant in the upload flow)
- All bookshelf operations
- Search, prices, reviews (enrichment pipeline unaffected)
- Marketplace

---

## Diagnosis

### Step 1: Check Modal service status

Visit [https://modal.statuspage.io](https://modal.statuspage.io) or the Modal dashboard at [https://modal.com/apps](https://modal.com/apps).

Look for:
- Incidents or degraded performance on GPU inference
- Container cold start delays (Modal sometimes reports these separately)

### Step 2: Check Oban vision queue

```sql
-- Queue depth by state
SELECT state, count(*) FROM oban_jobs WHERE queue = 'vision' GROUP BY state;

-- Recent failures
SELECT id, attempted_at, errors
FROM oban_jobs
WHERE queue = 'vision' AND state IN ('retrying', 'discarded')
ORDER BY attempted_at DESC
LIMIT 20;
```

Expected output during Modal outage: large number of `retrying` jobs, `errors` column contains `connection refused` or HTTP 5xx from Modal.

### Step 3: Check circuit breaker state

Via IEx on the running instance:
```bash
fly ssh console -a thestacks-core
```
```elixir
iex> Fuse.ask(:vision_service)
# :ok = circuit is closed (requests flowing)
# :blown = circuit is open (requests blocked, system is protecting itself)
```

If `:blown`, the circuit opened automatically after 5 failures in 60 seconds. Vision jobs are snoozing and will retry when the circuit resets (every 5 minutes by default).

### Step 4: Verify HMAC configuration is intact

```bash
fly secrets list -a thestacks-core | grep VISION
fly secrets list -a thestacks-vision  # Modal app, if accessible
```

Both `VISION_HMAC_SECRET` values must match. Mismatched secrets cause 401 errors (not timeouts) — if logs show 401, this is an auth issue, not an outage.

### Step 5: Test Modal endpoint directly

```bash
# Get the Modal endpoint URL from app config
fly ssh console -a thestacks-core
# Then from the iex prompt:
iex> Application.get_env(:stacks, :vision_service_url)
```

```bash
# Health check the Modal endpoint (unauthenticated health endpoint)
curl -s https://<modal-endpoint-url>/health
# Expected: {"status": "ok"}
# If timeout: Modal service is down
# If 401: HMAC auth issue (not an outage)
```

---

## Response

### Immediate

1. **Confirm it is a Modal issue** (not HMAC config drift) by checking the `/health` endpoint response code.
2. **Notify users** if this is likely to last more than 30 minutes: add a status message to the platform (if a status banner mechanism exists) or post to the platform's community channel.
3. **Do nothing to Oban** — the circuit breaker is already protecting the platform. Jobs will retry automatically when Modal recovers. Do not manually cancel vision jobs.

### If Modal is taking > 2 hours to recover

1. Consider whether to temporarily surface a more informative user message in the upload UI.
2. Check whether the Modal app needs to be redeployed:
   ```bash
   cd /path/to/thestacks
   modal deploy apps/vision/modal_app.py
   ```
   This triggers a fresh container build. If Modal's infrastructure is degraded, this may not help, but it's worth trying if the outage appears to be related to a specific deployment.

### If the VISION_HMAC_SECRET has drifted

```bash
# Regenerate and sync the secret to both locations
NEW_SECRET=$(openssl rand -hex 32)

# Update Fly.io core app
fly secrets set VISION_HMAC_SECRET="$NEW_SECRET" -a thestacks-core

# Update Modal (via Modal dashboard or CLI)
modal secret create vision-secrets VISION_HMAC_SECRET="$NEW_SECRET"
```

After updating, deploy both services to pick up the new secret.

---

## Recovery

**Self-healing (most common case):**
- Modal resolves the outage.
- Circuit breaker resets automatically every 5 minutes (checks `:vision_service` health).
- Oban jobs in `retrying` state resume automatically on their next scheduled retry.
- No operator action required beyond monitoring.

**Verify recovery:**
```sql
-- Check that vision jobs are transitioning from retrying to completed
SELECT state, count(*) FROM oban_jobs WHERE queue = 'vision' GROUP BY state;
-- Expected recovery pattern: retrying count falls, completed count rises
```

```bash
# Metrics dashboard
# Check "Vision identification success rate" — should return to > 90%
# Check "Oban vision queue depth" — should fall as jobs complete
```

**Test an identification manually:**
Upload a clear book photo via the frontend. Expect 15–30 second response (cold start) on first upload after outage. Subsequent uploads in the same session should be faster (warm container).

---

## Post-Incident

- Note the outage duration and any user-facing impact in the platform changelog.
- If this is the second Modal outage in a month: evaluate the keep-warm trade-off (cost vs. cold-start improvement) — currently ruled out as anti-pattern (ADR 001), but evidence of frequent outages may change the calculus.
- If HMAC drift caused the issue: document how the drift occurred and add a monitoring check for HMAC secret synchronisation.
