# Runbook: Neon PostgreSQL — Backup & Restore

**Severity:** P0 when invoked in anger (data loss on production)
**Owner:** Platform operator
**Last reviewed:** 2026-09-02 (drill executed and transcribed below)

The platform has **no external backup system**. Recovery is Neon's
point-in-time restore: every branch keeps a write-ahead history, and a new
branch can be created *from any moment inside that history*. Restoring is
therefore branching-from-the-past, verifying, and repointing — not restoring a
dump.

---

## ⛔ The number that decides everything: the retention window

Both Neon projects run with `history_retention_seconds = 21600` — **six
hours**, the free-plan ceiling.

- Data loss noticed **within 6 hours** → fully recoverable to any second
  inside the window.
- Data loss noticed **later than 6 hours** after it happened → **not
  recoverable by this runbook or any other**. There is no dump, no snapshot,
  no second copy.

Two consequences worth stating plainly:

1. **Detection latency is the real backup policy.** Anything that delays
   noticing corruption — a quiet weekend, an unmonitored deploy — consumes the
   only recovery window that exists.
2. If the platform ever holds data whose loss would be unacceptable after a
   sleepy Saturday, either the retention window must be bought up (Neon paid
   plans extend it to days) or a periodic `pg_dump` to object storage must be
   added. That decision is deliberately left open here; this runbook documents
   what IS, not what ought to be.

---

## Restore procedure

Everything below uses the Neon API with `NEON_API_KEY` (prod project
`thestacks`) or `NEON_STAGING_API_KEY` (staging project). Connection URIs
carry credentials — resolve them into variables, never into terminal output
or transcripts.

### 1. Stop the bleeding

If the damage is ongoing (a bad job, a runaway migration), stop the writer
first — `fly scale count 0 --app thestacks-core` is the blunt instrument.
Every second of continued writes pushes good history further toward the back
of the 6-hour window.

### 2. Pick the restore point

The latest moment you are confident is *before* the damage, as an ISO-8601
UTC timestamp. Err early: a restore point one minute too late replays the
damage; one minute too early loses a minute of writes.

### 3. Branch from the past (the actual restore)

```sh
curl -s -H "Authorization: Bearer $NEON_API_KEY" \
  -H "content-type: application/json" \
  -X POST "https://console.neon.tech/api/v2/projects/<project>/branches" -d '{
    "branch": {
      "name": "restore/<incident-date>",
      "parent_id": "<damaged-branch-id>",
      "parent_timestamp": "<T0-iso8601>"
    },
    "endpoints": [{"type": "read_write"}]
  }'
```

Poll the branch until `current_state` is `ready` (seconds, not minutes — the
drill below measured 9s to ready-and-verified).

### 4. Verify BEFORE repointing — the integrity checklist

Run against the restore branch, comparing to the last known-good numbers:

- [ ] `SELECT count(*) FROM op.users;` matches expectation
- [ ] `SELECT count(*) FROM op.books;` matches expectation
- [ ] The specific lost/corrupted object is present and correct on the restore
- [ ] `SELECT count(*) FROM op.schema_migrations;` — 128 as of 2026-09-02;
      must match the deployed release's expectation
- [ ] Spot-read one recently-written row you know the content of

A restore that fails any line is the wrong restore point — delete the branch
and re-branch earlier. Branches are cheap; repointing at a wrong restore is
not.

### 5. Repoint production

Prod's `DATABASE_URL` is composed at deploy time (see
`docs/runbooks/prod-data-access.md` for how it is resolved). Repoint by
updating the Fly secret to the restore branch's URI and `fly secrets deploy`
— a staged secret does **not** take effect on machine restart alone. Then
scale the app back up and watch `/api/health`.

The damaged branch stays as the parent — do not delete it until the incident
review is done; it is the forensic record.

### 6. Afterwards

- The restore branch is now production; rename it accordingly.
- Write the incident down while the timeline is fresh, including the gap
  between damage and detection — that gap versus the 6-hour window is the
  finding that matters.

---

## Drill transcript — 2026-09-02, preview stack (owner-ruled scope)

Executed against the disposable `preview/fix-general-clean-up` branch of the
staging project. Sequence: seed a sentinel table → record T0 state → inflict
real damage (DROP TABLE + DELETE) → restore via `parent_timestamp` branch →
verify → measure.

```
== 1. seed a sentinel + record pre-incident state ==
  T0=2026-09-02T13:41:22.415312+00:00  users=20 books=169 sentinel=1

== 2. the incident — destructive loss AFTER T0 ==
  incident at 2026-09-02T13:41:30Z: sentinel table DROPPED, op.user_blocks emptied

== 3. RESTORE — new branch from source at T0 ==
  restore branch: br-shiny-firefly-anpuvzby (parent_timestamp = T0)

== 4. integrity checklist on the restored branch ==
  users:      T0=20   restored=20    ✅
  books:      T0=169  restored=169   ✅
  sentinel:   T0=1    restored=1     ✅  (the table was DROPPED on the source)
  migrations: 128 rows intact
  RTO: 9s from restore-start to verified

== 5. cleanup ==
  drill branch deleted
```

**Measured RTO: 9 seconds** from issuing the restore to a verified branch —
excluding the repoint-production step (secret update + machine restart), which
adds minutes, and excluding detection latency, which is unbounded and is the
real risk (see the retention window above).

What the drill deliberately did not prove: repointing a live app at the
restored branch (the preview app was not repointed), and prod-project
behaviour (same API, same mechanism, but executed on staging by owner ruling
— prod drives were scoped to the preview for this campaign).

---

## Related

- `docs/runbooks/neon-outage.md` — diagnosis when the database is *down*
  rather than *damaged*; this runbook takes over when the data itself is the
  problem.
- `docs/runbooks/prod-data-access.md` — how prod's `DATABASE_URL` is composed
  and safely resolved.
- `docs/runbooks/migration-recovery.md` — when the damage is a migration.
