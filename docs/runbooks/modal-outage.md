# Runbook: Modal Vision Service — Outage

**Severity:** P2 (partial feature degradation — manual ISBN entry remains functional)
**Owner:** Platform operator
**Last reviewed:** 2026-06-10

The production Modal app is `thestacks-vision` (per `apps/vision/modal_app.py`, default `MODAL_APP_NAME`). Per-PR preview deploys use `thestacks-vision-<sanitised-branch>` (per `scripts/deploy-stack.sh` — branch lowercased, `/_` → `-`, truncated to 30 chars). Substitute the right app name in the commands below when triaging a preview rather than production.

---

## Symptoms

**User sees:**
- Photo upload stalls on "Identifying your book..." with no progress after 60 seconds
- Upload eventually fails with a generic error message
- Manual ISBN entry (the fallback path) continues to work normally

**Operator sees:**
- Oban `vision` queue depth growing in `oban_jobs` table
- Jobs in `scheduled` or `retrying` state with `Stacks.AI.Client` errors in logs
- Circuit breaker `:vision_fuse` may be blown — check `:fuse.ask(:vision_fuse, :sync)`
- Phoenix logs: `[error] Vision service unreachable: connection refused / timeout`
- Metrics dashboard: identification success rate dropping toward 0%
- If Modal has disabled the workspace for non-payment or quota: vision HTTP calls return `404` with body `modal-http: workspace ac-* is disabled` — see [`budget-exhaustion.md`](budget-exhaustion.md), but recovery is the same as for an outage (this runbook)

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

Then list our own apps and tail logs from the affected one:
```bash
modal app list
modal app logs thestacks-vision         # prod
# or: modal app logs thestacks-vision-<sanitised-branch>  for a preview
```

Look for repeated cold-start failures, OOM on the A10G, or the workspace-disabled banner. Recall the inference stack: HuggingFace Transformers + `Qwen/Qwen2.5-VL-7B-Instruct` in bfloat16 on A10G (single inference per container, scales horizontally via `max_containers=10`). Image-build failures show up here before they show up as 5xx on `/analyze`.

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
iex> :fuse.ask(:vision_fuse, :sync)
# :ok    = circuit is closed (requests flowing)
# :blown = circuit is open (requests blocked, system is protecting itself)
# {:error, :not_found} = fuse not installed (Stacks.CircuitBreakers not started — reboot the app)
```

If `:blown`, the circuit opened automatically after 5 failures in 60 seconds. Vision jobs are snoozing and will retry when the circuit resets (every 5 minutes by default).

To reset the circuit manually (after confirming Modal has recovered):
```elixir
iex> :fuse.reset(:vision_fuse)
```

### Step 4: Verify HMAC configuration is intact

```bash
fly secrets list -a thestacks-core | grep VISION
modal secret list | grep thestacks-vision   # Modal app secret (named `thestacks-vision`)
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
3. If a preview deploy's Modal app is wedged and blocking E2E, stop it explicitly rather than waiting for the workspace-cleanup script:
   ```bash
   modal app stop thestacks-vision-<sanitised-branch>
   ```

### If the VISION_HMAC_SECRET has drifted

```bash
# Regenerate and sync the secret to both locations
NEW_SECRET=$(openssl rand -hex 32)

# Update Fly.io core app
fly secrets set VISION_HMAC_SECRET="$NEW_SECRET" -a thestacks-core

# Update the Modal secret (named `thestacks-vision`, per apps/vision/modal_app.py).
# --force overwrites the existing secret rather than erroring on conflict;
# the same syntax is what scripts/deploy-stack.sh uses.
modal secret create thestacks-vision VISION_HMAC_SECRET="$NEW_SECRET" --force
```

After updating, deploy both services to pick up the new secret.

---

## Recovery

**Self-healing (most common case):**
- Modal resolves the outage.
- Circuit breaker resets automatically every 5 minutes (`:vision_fuse` resets via `{:reset, 300_000}` config).
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

---

## See also

- [`docs/decisions/001-modal-over-together-ai.md`](../decisions/001-modal-over-together-ai.md) — why Modal owns vision inference (and why keep-warm is an anti-pattern)
- [`docs/decisions/015-vision-service-architecture.md`](../decisions/015-vision-service-architecture.md) — current vision service architecture (HF Transformers + Qwen2.5-VL-7B-Instruct on A10G)
- [`docs/runbooks/budget-exhaustion.md`](budget-exhaustion.md) — when the workspace is disabled by spend cap rather than a Modal-side outage
- [`docs/runbooks/vision-hallucination.md`](vision-hallucination.md) — when the model is up but returning garbage (not an outage)
- [`docs/runbooks/vision-service-rollback.md`](vision-service-rollback.md) — when a recent vision deploy regressed and you need to roll back the Modal app
