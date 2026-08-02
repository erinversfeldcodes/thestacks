# Runbook: correct bad production data

Operator procedure for repairing rows that violate an invariant the application
has always claimed to hold — a stored value that is wrong, not a user's data
that is unwanted.

**This is not the GDPR erasure path.** If the request is "delete this person",
you want [`gdpr-erase-user.md`](gdpr-erase-user.md). This runbook is for "this
row says something untrue about a book".

## The rule

> A correction to production data is a reviewed, dry-runnable, audited
> operation. Not a `psql` session, not an `UPDATE` buried in a migration.

Four properties hold for every correction, and each is worth knowing before you
run one:

| Property | What it means for you |
|---|---|
| **Dry-run by default** | Every entry point reports what it *would* change and writes nothing until you explicitly ask. Read the blast radius first; that is what it is for. |
| **Idempotent** | Running twice is safe. The second run reports zero rows. If it does not, something is wrong — stop and read the plan. |
| **Audited in the same transaction as the change** | A change that cannot be recorded does not happen. There is no window in which a row moved and nothing says why. |
| **Fails loudly** | On the deploy path it raises, so `set -e` aborts the deployment while the *old* image is still serving traffic. Over the API it is a non-2xx with the reason verbatim. |

## Which entry point

There are three, and they are the same mechanism
(`Stacks.DataCorrection.Registry`) reached three ways.

### 1. Automatically, during every deploy

`Stacks.Release.deploy/0` is Fly's `release_command`, and it runs the registered
corrections **before** migrating. That order is deliberate: a migration that
adds a constraint to an existing table is a claim about existing data, so a
repair has to land ahead of the constraint that would otherwise reject the row
(Issue #339, where exactly that aborted two preview deployments).

You do not invoke this. It is why a restored backup or a re-branched database
repairs itself.

### 2. As the platform owner, against a running stack

The path to reach for when a reader reports something wrong and you have no
shell. Requires an MFA-verified admin session on an **owner** account.

```sh
# 1. See what needs correcting. This writes nothing.
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://thestacks.app/api/admin/data_corrections | jq .

# 2. Read the `report` field of the correction you care about. It names every
#    row, its current value, its new value, and why. That is the blast radius.

# 3. Apply exactly one, with a reason. The reason is not optional.
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reason":"reader reported the book could not be found by its barcode"}' \
  https://thestacks.app/api/admin/data_corrections/normalise_edition_isbn10/apply | jq .
```

`GET` is the dry run — there is no flag to forget. `POST .../apply` is the only
thing that writes.

Getting `$ADMIN_TOKEN`: `POST /api/admin/auth/login` then
`POST /api/admin/auth/verify_mfa`, same as every other break-glass endpoint. The
session lasts 30 minutes and is bound to your IP.

### 3. From a shell, against any database

```sh
# from apps/core/
mix stacks.data.correct                                   # dry-run everything
mix stacks.data.correct --only normalise_edition_isbn10   # dry-run one
mix stacks.data.correct --apply                           # write

# on a deployed stack, where there is no mix
/app/bin/core eval 'Stacks.Release.correct_data()'
/app/bin/core eval 'Stacks.Release.correct_data(apply: true)'
```

## Reading the result

A report looks like this:

```
data-correction: normalise_edition_isbn10 (dry_run)
  scope: op.book_editions rows whose isbn is 10 digits with a valid ISBN-10 check digit
  reversible: the ISBN-10 is recoverable from the ISBN-13 by arithmetic, and the
              audit row keeps it — but nothing should reverse it: the column has
              always meant ISBN-13
  rows:  2
  - 7f6813d8-…: "0071615695" -> "9780071615693"  (ISBN-10 stored unnormalised; …)
  DRY RUN — nothing was written. Re-run with --apply to write.
```

- **`scope`** is the correction's own claim about which rows it may touch. If a
  row you did not expect is listed, the correction is wrong, not the row.
- **`reversible` / `one-way`** is stated before you run, because "can I put it
  back?" is the question you will ask afterwards. Most corrections are one-way:
  the old value was not valid, so nothing should restore it.
- **`rows: 0`** on a second run is the idempotence guarantee working.

## The audit trail

Every changed row writes one `audit.audit_log` row with action
`data.correction.applied`, inside the change's transaction. The encrypted
metadata carries the correction's name, its scope, its reversibility, the old
value, the new value, the per-row reason (`because`), the entry point
(`invoked_by`), and — when a human invoked it — your operator reason. The row's
`user_id` is the operator.

Over the API you also get the usual `admin.call` row from
`StacksWeb.Plugs.AuditAdminCall`, carrying endpoint, latency and rows affected.

```sh
# via the admin API
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://thestacks.app/api/admin/audit_log?from=2026-08-01T00:00:00Z" | jq \
  '.entries[] | select(.action == "data.correction.applied")'
```

## When it fails

| Symptom | What happened | What to do |
|---|---|---|
| Deploy aborts with `data correction … failed` | A correction could not complete. **Nothing was committed** and the old image is still serving. | Read the reason in the deploy log. Dry-run against the same database to see the plan. |
| `{"error":"correction_failed","detail":"{:isbn_already_present, …}"}` | The repaired value collides with a row that already owns it. | This is a decision for you, not a retry. Two rows claim one ISBN; work out which is right before doing anything. |
| `{:row_no_longer_matches, id, from}` | The row moved between planning and applying. | Re-run the dry run. The plan you read is stale. |
| `{"error":"unknown_correction"}` | The name is not registered. | `GET /api/admin/data_corrections` lists every valid name. There is no way to name a correction that does not exist as reviewed code — that is deliberate. |
| `403` | Your account is not an owner, or was demoted after the admin session was minted. | The role is checked where the write happens, not only at login. Log in again as the owner. |

## Adding a correction

A correction is a code change and gets reviewed like one. There is no endpoint
that takes a table, a column and a value, and adding one would undo the property
this whole mechanism exists to hold.

1. Write a module implementing `Stacks.DataCorrection`'s five callbacks —
   `name/0`, `resource_type/0`, `scope/0`, `reversibility/0`, `plan/0`,
   `apply_change/1`. Use `Stacks.DataCorrection.Column` for the reads and the
   write, not the Ecto schema: a correction runs because reality and the schema
   disagree, and the changeset that normalises the bad value away is how a
   repair quietly becomes a no-op.
2. `plan/0` must return `[]` once applied. That is what makes the whole thing
   idempotent, and it is a property of your `SELECT`, not of the runner.
3. Add it to `Stacks.DataCorrection.Registry`. It is an explicit list on
   purpose — it is what bounds the rows the API can reach.
4. Test it the way `apps/core/test/stacks/data_correction_test.exs` tests the
   existing ones: dry run changes nothing, apply is idempotent, an audit row
   lands, and a row that has moved is refused.

### When a correction is the wrong tool

Two real cases where it was surveyed and rejected — the reasoning generalises:

- **The value has to be fetched, not derived** (Issue #346's resolver-identifier
  backfill). `plan/0` runs inside `fly deploy`, so a third-party lookup per row
  would put someone else's outage in the path of every deploy, and would never
  converge for a permanently unresolvable value. Use a job.
- **The repair takes an argument** — *which* two works to un-merge. `plan/0`
  takes none, so a targeted one-shot operation does not fit the standing-repair
  shape.

## Related

- `apps/core/lib/stacks/data_correction.ex` — the mechanism and its contract.
- [`prod-data-access.md`](prod-data-access.md) — the break-glass posture this
  sits inside (Issue #138).
- [`migration-recovery.md`](migration-recovery.md) — when the problem is the
  schema rather than the rows.
