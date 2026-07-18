# Runbook: GDPR erase a user

Operator procedure for a GDPR right-to-erasure request — deleting a single
user and all their data from production.

## What it does

The erasure (`Stacks.GDPR.Deletion.delete_user_data/2`) runs as one atomic
transaction:

- **Deletes** the user row, their bookshelves, placements, placement history,
  and revokes all sessions/tokens.
- **Anonymises** their comments in place (`body → "[deleted]"`, `author_id →
  nil`) so reply threads stay intact but the free-text PII is gone.
- **Scrubs `op.event_log` in place**: the event rows are immutable and are
  never deleted, but the erased user's `payload`/`metadata` are emptied to
  `{}`. What remains is the *trace* you're allowed to keep — the `user_id`
  (as `aggregate_id`), the `event_type`, and `occurred_at`: "this user_id
  existed and here are the actions they took", with no PII detail.
- **Writes a `user.data_deleted` audit row** (encrypted metadata carries your
  `reason`). The `user_id` is a random UUIDv4 and is never reused, so the
  audit row + scrubbed event rows are the permanent tombstone — no separate
  table.

The `user_id` is the erasure key. It's globally unique and consistent
everywhere; you resolve it from an **email** (contains `@`) or a **handle**.

## How to run it

Use the **GDPR erase user** GitHub Actions workflow
(`.github/workflows/gdpr-erase-user.yml`), `workflow_dispatch`.

### 1. Dry run first (default)

Leave **execute** unchecked. Fill in **identifier** (email or handle). Run.

The job resolves the user and prints `GDPR_ERASE_PREVIEW` — the per-target row
counts that *would* be erased — and deletes nothing. Confirm the resolved
`user_id` and counts look right (right person, plausible volume).

### 2. Execute

Re-run with:

- **identifier** — same email/handle.
- **execute** — checked.
- **reason** — your justification (e.g. a DSAR ticket reference). It is
  recorded **encrypted** in the audit row. **Do not put the subject's personal
  data in the reason.**
- **confirm** — re-type the exact identifier. Must match or the run aborts.

All three (execute + non-empty reason + matching confirm) are re-validated
inside the release function, so a fat-fingered dispatch fails closed.

The workflow runs `Stacks.Release.gdpr_erase_user/1` **inside the live prod
node** via `fly ssh console ... rpc`. Only `FLY_API_TOKEN` is exposed to CI —
the prod `DATABASE_URL` and `CLOAK_KEY` never leave Fly. Parameters are passed
as Base64(JSON) so there is no shell/Elixir injection surface.

The `gdpr-erasure` GitHub **Environment** gates the job. Configure it with
required reviewers (repo → Settings → Environments) so every run needs a second
person's approval.

## Warehouse propagation

The erasure scrubs the operational tables and event log immediately. The
analytics **warehouse** (dbt marts) is rebuilt from those sources by the daily
`DbtRefreshJob` full run (`apps/core/config/config.exs` crontab — `0 5 * * *`,
05:00 UTC). So warehouse copies of the user's data drop within **≤24h**. This
daily full refresh is a hard requirement for erasure timeliness — if you change
the crontab, keep a full refresh at least once every 24 hours.

If you need faster warehouse propagation for a specific request, trigger a dbt
full refresh manually after the erasure completes.

## Verifying afterwards

- Workflow output shows `GDPR_ERASE_RESULT deleted { ...counts... }`.
- `Accounts.get_user_by_email/get_user_by_handle` returns `nil` for the
  identifier.
- One `user.data_deleted` row exists in `audit.audit_log` with the user's id in
  `resource_id`, `user_id = nil`, and your reason in the (encrypted) metadata.
- `op.event_log` rows for that `user_id` still exist but have `payload = {}`.

## Failure modes

- **`GDPR_ERASE_ERROR no user found`** — identifier didn't resolve. Check for
  typos; remember email lookup is case-insensitive (downcased), handle lookup
  is trimmed + case-insensitive.
- **`confirmation does not match`** — `confirm` ≠ `identifier`. Re-type exactly.
- **rpc exit non-zero / no output** — the prod machine may be unreachable; the
  transaction is atomic, so a failure leaves the user fully intact. Retry.
