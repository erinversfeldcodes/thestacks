# Runbook: Neon PostgreSQL — Outage

**Severity:** P0 (total platform outage — no cached read path)
**Owner:** Platform operator
**Last reviewed:** 2026-03-19

---

## Symptoms

**User sees:**
- All API calls return 500 or timeout
- Login fails
- Shelf pages fail to load
- Upload fails at the database write step (after vision model call succeeds)

**Operator sees:**
- All Phoenix API calls returning 500
- Fly.io logs: `[error] Postgrex.Error: connection refused` or `DBConnection.ConnectionError: connection not available and request was dropped from queue after...`
- Oban jobs failing across all queues (Oban uses the same database connection)
- PromEx/Telemetry: database connection pool exhaustion metrics if the outage is partial (some connections timing out)
- Health check at `/api/health` returning 503 (if health check includes a DB ping)

---

## Impact

**Broken:**
- Entire platform — all features require database access

**Still working (if applicable):**
- Static asset serving (Elm SPA JavaScript, CSS) — these are served from Fly.io's edge cache, not the database
- The Modal vision service can still receive requests, but Oban cannot enqueue jobs

**Known limitation:** There is no cached read path in the current architecture. If Neon is down, the platform is fully unavailable. This is documented and accepted for Phase 1.

---

## Diagnosis

### Step 1: Check Neon status

Visit [https://neonstatus.com](https://neonstatus.com) or the Neon console at [https://console.neon.tech](https://console.neon.tech).

Look for:
- Active incidents on database availability
- Planned maintenance windows
- Regional degradation (Neon's IAD region matches Fly.io's IAD region)

### Step 2: Check Fly.io application logs

```bash
fly logs -a thestacks-core --no-tail | head -100
```

Look for:
- `DBConnection.ConnectionError` — connection pool exhausted or connection refused
- `Postgrex.Error: connection refused` — Neon is unreachable
- `ssl handshake failed` — SSL/TLS issue (check `?sslmode=require` in connection string)

### Step 3: Test the database connection directly

```bash
fly ssh console -a thestacks-core
```
```elixir
# Test from IEx
iex> Stacks.Repo.query("SELECT 1")
# :ok — database reachable
# {:error, ...} — database unreachable
```

If IEx is not available (app crash loop), test from outside:

```bash
# Get the DATABASE_URL (contains credentials — handle with care)
fly secrets list -a thestacks-core | grep DATABASE
# Use psql with the connection string from Neon console
psql "$DATABASE_URL"
```

### Step 4: Check connection pool status

```bash
fly ssh console -a thestacks-core
```
```elixir
# Check pool status
iex> DBConnection.Poolboy.status(Stacks.Repo)
# Or check via Telemetry metrics: db.pool.checked_out vs db.pool.size
```

If pool is at 100% checked-out and requests are being dropped: this indicates the database is responding slowly (not fully down) — could be Neon scale-to-zero cold start.

### Step 5: Check for Neon scale-to-zero cold start

Neon serverless databases can scale to zero after a period of inactivity. Cold start on Neon is typically 1–5 seconds. If this is the cause:

- Logs will show initial connection failures followed by eventual success
- The outage will be brief (< 30 seconds) and self-healing

To prevent scale-to-zero cold starts, configure Neon's "suspend compute" timeout appropriately in the Neon console.

---

## Response

### If Neon is reporting an incident

1. **Do nothing to the application** — any manual intervention risks making recovery harder.
2. **Monitor Neon's status page** for estimated recovery time.
3. **Communicate** the outage to platform users if it lasts more than 10 minutes.
4. **Do not restart the Fly.io machines** — Ecto's connection pool will reconnect automatically when Neon recovers. Restarting adds unnecessary downtime to the recovery.

### If Neon is not reporting an incident (connection issue is platform-side)

**Check 1: Connection string integrity**

```bash
fly secrets list -a thestacks-core | grep DATABASE_URL
```

The `DATABASE_URL` must contain `?sslmode=require`. If it was recently updated (e.g., Neon connection string rotation), the new string must be re-set:

```bash
fly secrets set DATABASE_URL="postgres://user:password@host/dbname?sslmode=require" -a thestacks-core
```

After updating secrets, the app restarts automatically.

**Check 2: Neon branch/compute health**

In the Neon console, verify:
- The production branch (`main`) is active
- The compute endpoint is running (not in a suspended/stopped state)
- No recent branch deletions or resets that might affect the production branch

**Check 3: Connection limit**

Neon's free tier limits concurrent connections. If the platform is hitting the connection limit:

```bash
# In Neon console: check active connections
SELECT count(*) FROM pg_stat_activity WHERE datname = 'stacks_production';
```

If at the limit, consider reducing Ecto pool size temporarily or upgrading the Neon plan.

---

## Recovery

**Self-healing (most common case):**
- Neon resolves the incident.
- Ecto's `DBConnection` pool attempts reconnection automatically.
- Oban resumes processing queued jobs.
- No manual intervention required.

**Verify recovery:**
```bash
fly logs -a thestacks-core --no-tail | tail -20
# Look for: successful Postgrex connections, absence of connection errors
```

```bash
# Test the health endpoint
curl https://thestacks.app/api/health
# Expected: {"status": "ok", "db": "connected"}
```

**Post-recovery: check for data consistency**

Oban jobs that were in `executing` state at the time of the outage may have been lost (if the Elixir process crashed without marking them complete). Check for orphaned executing jobs:

```sql
-- Jobs stuck in executing state (shouldn't exist after recovery)
SELECT id, queue, worker, attempted_at FROM oban_jobs
WHERE state = 'executing' AND attempted_at < NOW() - INTERVAL '10 minutes';
```

Oban has a built-in "rescue" mechanism that transitions orphaned `executing` jobs back to `available` after a configurable timeout. Verify this ran after recovery.

---

## Post-Incident

- **Document the outage:** Duration, impact (total unavailability), root cause.
- **Consider read replicas:** At 500+ users, a Neon read replica for `GET` endpoints would allow read-only access during a primary outage. See `docs/capacity-model.md` trigger points.
- **Consider a status page:** If outages are becoming frequent, a platform status page (e.g., via Statuspage.io or a simple static page) improves user trust.
- **Review connection string expiry:** Neon connection strings may have expiry dates depending on the plan. Set a calendar reminder to rotate before expiry.
