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
- **Scrubs `audit.audit_log` in place, on the same principle**: the user's own
  audit rows are kept — `user_id`, `action`, `resource_type`, `occurred_at`, so
  the platform can still answer "who did what, when" — and the two fields that
  carry the person are nulled: `metadata` (which holds free text and shelving
  detail) and `ip_address`. The IP goes because its digest is unkeyed and so
  recoverable: leaving it would keep the erased reader locatable through a
  column that only looks anonymous.
- **Writes a `user.data_deleted` audit row** (encrypted metadata carries your
  `reason`). This row is written *after* the scrub and carries `user_id = nil`,
  so your justification survives the pass that erases — it is the operator's
  accountability record, not the subject's data. The `user_id` is a random
  UUIDv4 and is never reused, so the audit row + scrubbed event and audit rows
  are the permanent tombstone — no separate table.

**`user_id` is the ONLY key the erasure accepts.** It's a globally-unique
UUIDv4; the erase workflow refuses anything that isn't a UUID, so it can never
resolve ambiguously to the wrong person. Email and handle are NOT unique keys
(two accounts can share an email at different casings; only the DB enforces
handle uniqueness), so resolving them lives in a *separate, read-only* lookup —
never in the destructive path.

## Who can run it

Both workflows are locked to a single operator two ways:

1. A **`Restrict operators`** step fails fast unless `github.actor` is
   `erinversfeldcodes`.
2. The **`gdpr-erasure` GitHub Environment** requires `erinversfeldcodes` to
   approve every run (repo → Settings → Environments → `gdpr-erasure` →
   Required reviewers).

To authorise more operators, add them to the `case` in both workflow files AND
to the environment's reviewers.

## How to run it — two steps

### Step 1 — resolve the user_id (`GDPR lookup user` workflow)

Run **GDPR lookup user** (`.github/workflows/gdpr-lookup-user.yml`) with
**query** = the subject's email or handle. It prints one
`GDPR_LOOKUP_MATCH user_id=… email=… handle=…` per match and a
`GDPR_LOOKUP_COUNT`. An email may return several `user_id`s (pick the right one
by the other fields); a handle returns at most one. This is read-only.

### Step 2 — dry run the erase (`GDPR erase user` workflow)

Run **GDPR erase user** (`.github/workflows/gdpr-erase-user.yml`) with
**user_id** = the UUID from step 1, **execute** unchecked. It prints
`GDPR_ERASE_PREVIEW` — the per-target row counts that *would* be erased — and
deletes nothing. Confirm the counts look right.

### Step 3 — execute

Re-run **GDPR erase user** with:

- **user_id** — the same UUID.
- **execute** — checked.
- **reason** — your justification (e.g. a DSAR ticket reference). Recorded
  **encrypted** in the audit row. **Do not put the subject's personal data in
  the reason.**
- **confirm** — re-type the exact `user_id`. Must match or the run aborts.

All three (execute + non-empty reason + matching confirm) are re-validated
inside the release function, so a fat-fingered dispatch fails closed.

Both workflows run inside the **live prod node** via `fly ssh console ... rpc`.
Only `FLY_API_TOKEN` is exposed to CI — the prod `DATABASE_URL` and `CLOAK_KEY`
never leave Fly. Parameters are passed as Base64(JSON) so there is no
shell/Elixir injection surface.

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
- `Accounts.get_user(<user_id>)` returns `nil`.
- One `user.data_deleted` row exists in `audit.audit_log` with the user's id in
  `resource_id`, `user_id = nil`, and your reason in the (encrypted) metadata.
- `op.event_log` rows for that `user_id` still exist but have `payload = {}`.
- `audit.audit_log` rows for that `user_id` still exist but have `metadata` and
  `ip_address` NULL. Note the asymmetry, which is deliberate: the trail is
  retained past erasure on a different lawful basis, but it IS disclosed to the
  person it describes — a subject-access export carries it under `audit_trail`. The counts map reports how many were scrubbed as
  `audit_log_rows_scrubbed`, and the dry-run preview shows the same number
  before you commit to anything.

## Failure modes

- **`GDPR_ERASE_ERROR user_id … is not a valid UUID`** — you passed an email or
  handle. Resolve it to a `user_id` with the lookup workflow first.
- **`GDPR_ERASE_ERROR no user exists with user_id …`** — valid UUID, but no such
  user (typo, or already erased).
- **`confirmation does not match user_id`** — `confirm` ≠ `user_id`. Re-type
  exactly.
- **Lookup returns `GDPR_LOOKUP_COUNT 0`** — no account matches; check the
  email/handle. Multiple matches → disambiguate by the printed email/handle.
- **rpc exit non-zero / no output** — the prod machine may be unreachable; the
  transaction is atomic, so a failure leaves the user fully intact. Retry.
