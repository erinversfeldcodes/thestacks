# Runbook: R2 Object Storage — Data Loss

**Severity:** varies by prefix (see below — from P1 to "no action")
**Owner:** Platform operator
**Last reviewed:** 2026-09-02

One bucket (`stacks-images` by default, `R2_BUCKET_NAME`). Everything in it is
either reproducible, expiring by design, or a backup of something whose source
of truth lives elsewhere. **No R2 prefix is a system of record** — that is the
single most useful fact in an incident.

---

## Impact assessment, per prefix

### `uploads/{image_id}` — reader photos awaiting/after identification

- **What it is:** the image bytes a reader submitted; the identification
  pipeline reads them via presigned URL.
- **Retention by design:** 30 days, enforced by `ImageRetention`
  (`stacks_gdpr_image_expired_count_total` counts the sweep). Loss is
  therefore *at most* a 30-day window, and usually much less.
- **Loss impact:** an identification currently in flight fails (the vision
  service 404s the presigned fetch) — the reader sees the failure state and
  can re-photograph. Already-shelved books are unaffected: the book/edition/
  placement rows are in Postgres; the image was only the identification input.
- **Verdict:** P3. Annoying for in-flight uploads, self-healing, nothing
  irreplaceable. **Do not back these up** — a backup would *extend* retention
  of personal images the GDPR design deliberately expires.

### `exports/{user_id}/{deadline}-{token}.json` — GDPR export archives

- **What it is:** a complete copy of one reader's personal data, awaiting
  download; TTL-swept past its deadline (`ExportRetentionJob`).
- **Loss impact:** a reader's download link 404s. Recovery is re-requesting
  the export — the source data is Postgres, regeneration is the normal path.
- **Verdict:** P3 for availability, and **losing these is privacy-positive**
  rather than harmful. Never back these up; a second copy of export archives
  is exactly what the orphan alarm (`stacks_gdpr_export_orphan_count_total`)
  exists to prevent.

### `backups/prod/prod-{timestamp}.dump` — the nightly database dumps

- **What it is:** `pg_dump` custom-format archives written by the
  `backup-dump` workflow (see `docs/runbooks/backup-restore.md`).
- **Loss impact:** the recovery net beyond Neon's 6-hour PITR window is gone
  until the next nightly run. The live database is untouched.
- **Verdict:** **P1 while it lasts** — not because data is lost (it isn't,
  yet) but because the exposure window is open: any database damage noticed
  late now has nothing to fall back on. Re-run the workflow manually
  (`gh workflow run backup-dump.yml`) rather than waiting for the schedule.

### Marketplace listing photos — **not in R2 at all**

`op.listings.photo_urls` is an array of URL strings; **no code path writes
marketplace photos to storage** (the complete writer inventory is
`Stacks.Uploads` → `uploads/` and `GDPR.ExportDelivery` → `exports/`). Today
those URLs point wherever the seller pasted them.

**Strategy (recorded, not yet built):** when marketplace photos become
platform-hosted, give them their own prefix (`listings/{listing_id}/…`) and
enable **R2 object versioning on that prefix alone**. Versioning is wrong for
`uploads/` and `exports/` (both *want* deletion to be final — retention and
privacy respectively) but right for listing photos, which are commercial
content a seller expects to survive an accidental overwrite. Until then, the
honest statement is: marketplace photos are not ours to lose, and also not
ours to protect.

---

## Diagnosis

- Bucket-wide vs prefix-scoped: `aws s3 ls s3://$R2_BUCKET_NAME/ --endpoint-url
  https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com` — an empty top level means
  bucket-level loss (Cloudflare incident or deletion); a single missing prefix
  points at the app's own sweeps first (`ImageRetention`,
  `ExportRetentionJob`) before assuming external cause.
- The storage circuit breaker and `stacks_gdpr_image_stuck_count_total` are
  the app-side signals that R2 operations are failing.

## Related

- `docs/runbooks/backup-restore.md` — the database side, and the dump
  workflow whose artefacts live under `backups/`.
- `docs/runbooks/gdpr-erase-user.md` — erasure touches `uploads/` and
  `exports/`; a "missing" object during erasure verification may simply be a
  sweep that already ran.
