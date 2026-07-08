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
- Marketplace notification (sale, new offer) not received
- Group invitation email not received

**Operator sees:**
- Oban `notifications` queue: `Stacks.Workers.EmailDeliveryJob` jobs in `retrying` or `discarded` state
- Logs: `[error]` from `Stacks.Email.Mailer` / Swoosh on a failed `Mailer.deliver/1` (HTTP 4xx/5xx from Resend)
- Resend dashboard: delivery failures, bounce rate spike, or API error rate increase

---

## Impact

**Broken / Degraded:**

| Email type | Impact if broken |
|-----------|-----------------|
| Registration confirmation | Email confirmation is always required (Issue #084); new users cannot complete registration |
| Password reset | Users who forget their password cannot recover access |
| WishList availability notification | Users miss notification when a wanted book becomes available |
| Marketplace sale notification | Sellers/buyers not notified of a completed transaction |
| New offer notification | Sellers not notified when a buyer makes an offer on a listing |
| Group invitation | Invitees do not receive the invitation link |
| GDPR export ready / opt-out confirmation | Users do not receive confirmation of GDPR actions |

**Still working:**
- All platform features that don't require email confirmation
- Existing authenticated users can still use the platform normally
- Registration creates accounts but new users cannot log in until email is confirmed — email delivery failure blocks all new signups

---

## Diagnosis

### Step 1: Check Resend status

**Resend:** [https://resend-status.com](https://resend-status.com)

Check for active incidents or degraded delivery. (The production mailer is wired to `Swoosh.Adapters.Resend` in `config/runtime.exs`, gated on `EMAIL_PROVIDER=resend`. There is no Postmark fallback currently configured.)

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
fly logs -a thestacks-core | grep -iE "email|resend|swoosh|Mailer" | tail -50
```

Common errors:
- `HTTP 401 Unauthorized` — API key invalid or expired
- `HTTP 422 Unprocessable Entity` — Email address invalid (bounce) or domain not configured
- `HTTP 429 Too Many Requests` — Rate limit hit (Resend free tier caps apply; `Stacks.Email` also enforces an internal 10/user/hr and 100/hr global cap)
- `HTTP 503 Service Unavailable` — Provider outage

### Step 4: Verify provider is configured and API key is valid

```bash
fly secrets list -a thestacks-core | grep -E "EMAIL_PROVIDER|RESEND_API_KEY"
```

Both `EMAIL_PROVIDER=resend` and `RESEND_API_KEY` must be set — `config/runtime.exs` only wires the Resend adapter when `EMAIL_PROVIDER == "resend"`. Without it, the mailer falls back to `Swoosh.Adapters.Local` (configured in `apps/core/config/config.exs`) and emails are silently captured in a local mailbox, never sent.

Send a test email by enqueueing a real job (there is no `Stacks.Email.ping/0`):
```bash
fly ssh console -a thestacks-core
```
```elixir
# Enqueue a registration confirmation to a known test user
iex> user = Stacks.Accounts.get_user_by_email("ops-test@thestacks.app")
iex> Stacks.Email.send_registration_confirmation(user)
# Then watch the notifications queue for the job to complete:
iex> import Ecto.Query
iex> Core.Repo.all(
...>   from j in Oban.Job,
...>   where: j.worker == "Stacks.Workers.EmailDeliveryJob",
...>   order_by: [desc: j.inserted_at], limit: 5
...> )
```

### Step 5: Check domain authentication (SPF/DKIM)

A common cause of delivery failures is domain authentication misconfiguration. If SPF/DKIM/DMARC records are missing or incorrect, major providers (Gmail, Outlook) may silently reject or junk emails.

Check in the Resend dashboard:
- Domain verification status for `thestacks.app`
- SPF record: should include `include:amazonses.com` (Resend's underlying SPF host)
- DKIM record: public key must be present in DNS as a TXT record

```bash
# Check SPF record
dig TXT thestacks.app | grep "v=spf"

# Check DKIM (Resend uses the "resend._domainkey" selector by default)
dig TXT resend._domainkey.thestacks.app
```

---

## Response

### If the email provider is reporting an incident

1. Do nothing to the application. Oban will retry email jobs automatically (`EmailDeliveryJob` is configured with `max_attempts: 3`).
2. Check when the retry window closes — Oban retries with exponential backoff. After 3 attempts a job is `discarded` and will not retry on its own; if the outage is long, expect some jobs to land in `discarded` before the provider recovers.
3. If critical emails (registration confirmation, password reset) are discarded: re-trigger after recovery (see "Re-queuing discarded email jobs" below).

### If the API key has expired

```bash
# Generate a new API key in the Resend dashboard, then update the Fly.io secret
fly secrets set RESEND_API_KEY="re_newkey_..." -a thestacks-core
```

After updating, the app restarts. Test immediately by enqueueing a real send (see Step 4 above) and confirming the resulting Oban job reaches `completed`.

### If domain authentication has lapsed (SPF/DKIM issue)

1. In the DNS provider for `thestacks.app`, verify:
   - SPF: `v=spf1 include:amazonses.com ~all` (Resend sends via SES under the hood)
   - DKIM: TXT record at `resend._domainkey.thestacks.app` with the public key from the Resend dashboard
   - DMARC: `v=DMARC1; p=quarantine; rua=mailto:dmarc@thestacks.app`

2. Re-verify the domain in the Resend dashboard after updating DNS records.

3. DNS propagation takes up to 48 hours. During this period, some emails may still fail delivery.

### Re-queuing discarded email jobs

If Oban has discarded email jobs during the outage (exceeded max retries), they can be manually retried:

```sql
-- Find discarded email jobs
SELECT id FROM oban_jobs
WHERE queue = 'notifications'
  AND worker = 'Stacks.Workers.EmailDeliveryJob'
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
iex> import Ecto.Query
iex> Oban.Job
     |> where([j], j.state == "discarded" and j.worker == "Stacks.Workers.EmailDeliveryJob")
     |> Core.Repo.all()
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

- If the API key expires: add the expiry date to a calendar reminder 30 days in advance. See `docs/runbooks/secrets-rotation.md` (covers `RESEND_API_KEY` rotation).
- If domain authentication lapsed: set a 6-month calendar reminder to re-verify domain DNS records.
- Consider adding email delivery success rate as a metric on the metrics dashboard (via Resend webhooks for delivery status).
- Email confirmation is always required (Issue #084 removed the `REQUIRE_EMAIL_CONFIRMATION` flag) — email delivery failure blocks new signups. Document the impact on new user onboarding in the SLA.
- Consider a secondary email provider as fallback (e.g., primary: Resend, fallback: AWS SES) for registration confirmation and password reset — these are the most critical email types. This is not currently configured.
