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

The erasure scrubs the operational tables and event log immediately.

**The warehouse holds no copy of the erased user's personal data, and there is
nothing to wait for.** Verified against the deployed database on 2026-10-16,
after the first successful dbt build there.

### Why — measured, not assumed

Of the 50 relations the warehouse builds, **48 are views**: all 40 in `staging`,
all 8 in `intermediate`, and 2 of the 4 in `marts`. A view stores nothing. The
personal data those views project — `stg_users.email`, `display_name`, `handle`,
`city`; `stg_post_comments.body`; `stg_blog_posts.body`; `stg_authors.bio` —
lives only in `op`, so the moment the erasure deletes the `op` row it is gone
from the view too. Erasure there is **immediate**, not daily.

The only two relations that hold a copy are the incremental marts, and neither
carries personal data:

| mart | columns | personal data |
|---|---|---|
| `marts.mart_community_read_count` | `book_id`, `read_count`, `last_refreshed_at` | none — `read_count` is a `count(distinct user_id)` aggregate and stores no identifier |
| `marts.mart_platform_searchable` | `book_id`, `title`, `author_name`, `primary_isbn`, cover URL, `description`, `language`, `visibility_tier` | none — book metadata; `author_name` is a published author, not a platform user |

So **no "warehouse copy" of a data subject's information exists to report on**, and
an erasure needs no warehouse step. Say that, rather than quoting a window.

### What the daily rebuild is actually for

`.github/workflows/scheduled-dbt-refresh.yml`, `cron: "11 4 * * *"` — daily at
04:11 UTC — runs `dbt build --full-refresh`. Its job is **correctness of the two
mart aggregates**, not erasure.

It matters here for one indirect reason worth knowing before you answer a
question about it: those two marts are incremental, and their refresh window
keys on surviving rows' `created_at`/`updated_at`. A deletion updates no
surviving row, so without the full refresh a deleted placement's book keeps its
old `read_count` **indefinitely** — measured: 3 before, 2 in truth, still 3
after an incremental refresh. That is wrong data derived from an erased user
rather than retained personal data, but if someone asks "does anything about me
survive in your analytics?", the honest answer is that an aggregate count may be
off by one for up to 24 hours and carries no identifier.

**The cron line is therefore an accuracy SLA, not an erasure SLA.** If it
changes, the 24 hours above changes with it.

### How to check it actually ran

Do not infer it from a green workflow badge. The previous arrangement was green
for months while the warehouse stayed empty. Read the far-end value:

    stacks_dbt_refresh_last_success_timestamp_seconds{target="production"}

`now()` minus that gauge is how stale the two mart aggregates are. If it exceeds
24 hours, say that the aggregate counts may be out of date — not that a
warehouse copy of the subject's data may still exist, because per the table
above there is no such copy to begin with.

### What this section used to say

It promised that "warehouse copies drop within ≤24h" via the daily
`DbtRefreshJob` full run. Two things were wrong with that, in opposite
directions, and both are worth keeping.

**The mechanism did not exist.** The job fired from an Oban crontab entry on a
machine configured to scale to zero, shelling a binary the runtime image does
not contain, targeting schemas that did not exist. Verified 2026-10-16 before
the fix — the `wh` schema held **zero tables** and dbt had never run against a
deployed database. The promise was satisfied only by there being nothing to
drop, which is not the same as being true.

**And the framing was wrong even once the mechanism worked.** "Warehouse copies
drop within 24 hours" implies copies that need dropping. There are none: the
layers that carry personal data are views, and the two relations that are
materialised carry none. An intermediate draft of this section restored the ≤24h
wording on the strength of the workflow now existing — which would have replaced
a false claim with a pessimistic and still-inaccurate one. The table above is
what the database actually showed.

Generalisable: when restoring a claim that was previously vacuous, re-derive it
from the system rather than reinstating the sentence. The mechanism existing is
not evidence that the sentence about it was right.

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
