# Runbook: Email Delivery Failure

**Severity:** P2 (user onboarding and notifications degraded — core platform unaffected)
**Owner:** Platform operator
**Last reviewed:** 2026-03-19

---

## Symptoms

**User reports:**
- Registration confirmation email not received
- Password reset email not received
- WishList availability notification not received
- Marketplace notification (sale, offer, shipping) not received

**Operator sees:**
- Oban `notifications` queue: `EmailDeliveryJob` jobs in `retrying` or `discarded` state
- Logs: `[error] Resend/Postmark API returned HTTP 4xx/5xx on email send`
- Resend/Postmark dashboard: delivery failures, bounce rate spike, or API error rate increase

---

## Impact

**Broken / Degraded:**

| Email type | Impact if broken |
|-----------|-----------------|
| Registration confirmation | If email confirmation is required, new users cannot complete registration |
| Password reset | Users who forget their password cannot recover access |
| WishList availability notification | Users miss notification when a wanted book becomes available |
| Marketplace sale notification | Sellers not notified of purchase — may not ship |
| GDPR export/delete confirmation | Users do not receive confirmation of GDPR actions |
| Partner approval notification | Partners not notified of approval status |

**Still working:**
- All platform features that don't require email confirmation
- Existing authenticated users can still use the platform normally
- Registration is possible if email confirmation is not yet required (check `REQUIRE_EMAIL_CONFIRMATION` env var)

---

## Diagnosis

### Step 1: Check Resend/Postmark status

**Resend:** [https://resend-status.com](https://resend-status.com)
**Postmark:** [https://status.postmarkapp.com](https://status.postmarkapp.com)

Check for active incidents or degraded delivery.

### Step 2: Check Oban notification queue

```sql
-- Email delivery failures
SELECT worker, state, count(*), max(attempted_at)
FROM oban_jobs
WHERE queue = 'notifications'
GROUP BY worker, state
ORDER BY state, count(*) DESC;

-- Specific error messages
SELECT id, worker, errors, attempted_at
FROM oban_jobs
WHERE queue = 'notifications'
  AND state IN ('retrying', 'discarded')
  AND worker LIKE '%Email%'
ORDER BY attempted_at DESC LIMIT 20;
```

### Step 3: Check Phoenix logs for API errors

```bash
fly logs -a thestacks-core | grep -i "email\|resend\|postmark" | tail -50
```

Common errors:
- `HTTP 401 Unauthorized` — API key invalid or expired
- `HTTP 422 Unprocessable Entity` — Email address invalid (bounce) or domain not configured
- `HTTP 429 Too Many Requests` — Rate limit hit (unlikely at Phase 1 scale)
- `HTTP 503 Service Unavailable` — Provider outage

### Step 4: Verify API key is valid

```bash
fly secrets list -a thestacks-core | grep EMAIL
```

Test the API key:
```bash
fly ssh console -a thestacks-core
```
```elixir
iex> Stacks.Email.ping()
# Should return :ok
# If {:error, :unauthorized}: API key is invalid
```

### Step 5: Check domain authentication (SPF/DKIM)

A common cause of delivery failures is domain authentication misconfiguration. If SPF/DKIM/DMARC records are missing or incorrect, major providers (Gmail, Outlook) may silently reject or junk emails.

Check in the Resend/Postmark dashboard:
- Domain verification status for `thestacks.app`
- SPF record: should include `include:sendgrid.net` (or the provider's SPF record)
- DKIM record: public key must be present in DNS as a TXT record

```bash
# Check SPF record
dig TXT thestacks.app | grep "v=spf"

# Check DKIM (Resend uses specific selector, e.g., "resend._domainkey")
dig TXT resend._domainkey.thestacks.app
```

---

## Response

### If the email provider is reporting an incident

1. Do nothing to the application. Oban will retry email jobs automatically.
2. Check when the retry window closes — by default, Oban retries with exponential backoff up to the configured max attempts. If the provider outage is long, some jobs may be discarded before recovery.
3. If critical emails (password reset) are discarded: manually re-trigger after recovery.

### If the API key has expired

```bash
# Generate a new API key in Resend/Postmark dashboard
# Then update the Fly.io secret
fly secrets set EMAIL_API_KEY="re_newkey_..." -a thestacks-core
```

After updating, the app restarts. Test immediately:
```elixir
iex> Stacks.Email.ping()
```

### If domain authentication has lapsed (SPF/DKIM issue)

1. In the DNS provider for `thestacks.app`, verify:
   - SPF: `v=spf1 include:<provider-spf-domain> ~all`
   - DKIM: TXT record at `<selector>._domainkey.thestacks.app` with the public key from the email provider
   - DMARC: `v=DMARC1; p=quarantine; rua=mailto:dmarc@thestacks.app`

2. Re-verify the domain in the Resend/Postmark dashboard after updating DNS records.

3. DNS propagation takes up to 48 hours. During this period, some emails may still fail delivery.

### Re-queuing discarded email jobs

If Oban has discarded email jobs during the outage (exceeded max retries), they can be manually retried:

```sql
-- Find discarded email jobs
SELECT id FROM oban_jobs
WHERE queue = 'notifications'
  AND state = 'discarded'
  AND inserted_at > NOW() - INTERVAL '24 hours';
```

```bash
fly ssh console -a thestacks-core
```
```elixir
# Retry a specific discarded job
iex> Oban.retry_job(job_id)

# Or retry all discarded email jobs (use with caution — may send duplicate emails)
iex> Oban.Job
     |> where([j], j.state == "discarded" and j.queue == "notifications")
     |> Repo.all()
     |> Enum.each(fn job -> Oban.retry_job(job.id) end)
```

**Caution:** Retrying notification jobs may send duplicate emails to users. Before doing this at scale, check whether the job logic is idempotent (does it deduplicate on the recipient side?).

---

## Recovery

**Self-healing:** Most email delivery issues self-heal when the provider recovers. Oban retries automatically within the retry window.

**Verify recovery:**
```sql
-- Check that notification jobs are completing
SELECT state, count(*) FROM oban_jobs
WHERE queue = 'notifications'
  AND inserted_at > NOW() - INTERVAL '2 hours'
GROUP BY state;
```

Expected: `completed` count rising, `retrying` count falling or zero.

**Test a real email:**
Register a new test account (if in a staging environment) and verify the confirmation email arrives within 60 seconds.

---

## Post-Incident

- If the API key expires: add the expiry date to a calendar reminder 30 days in advance.
- If domain authentication lapsed: set a 6-month calendar reminder to re-verify domain DNS records.
- Consider adding email delivery success rate as a metric on the metrics dashboard (via Resend/Postmark webhooks for delivery status).
- If email confirmation is currently required (`REQUIRE_EMAIL_CONFIRMATION=true`): document the impact of email failures on new user onboarding in the SLA.
- Consider a secondary email provider as fallback (e.g., primary: Resend, fallback: AWS SES) for registration confirmation and password reset — these are the most critical email types.
