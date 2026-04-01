# US-8.4 — Image Retention Policy

## 1. User Story

> **As a** user, **I want** my uploaded book photos to be automatically deleted after 30 days **so that** unnecessary personal data is not retained.

This is automatic. No user action required. When a book is added via photo upload, the original images are stored temporarily. Thumbnails are generated and kept for display purposes. After 30 days, the original full-resolution images are permanently deleted. Only thumbnails remain.

**What they see on the page:**
- On the Metrics Dashboard, the GDPR & Data section shows "Images pending deletion: [count]" -- the number of images that haven't yet reached their 30-day expiry.
- In Settings > Privacy, a note: "Uploaded photos are deleted after 30 days. Only thumbnails are kept."

---

## 2. UI Interaction Flow

### Happy Path
No user interaction. The system runs a nightly cleanup automatically.

1. User uploads a book photo (US-1.1.1).
2. Image is stored with an `expires_at` timestamp set to 30 days from upload.
3. Nightly `ImageRetentionJob` runs.
4. Job calls `cleanup_stuck_images/0` (images stuck in "pending" for > 2 hours).
5. Job calls `cleanup_expired_images/0` (images past their `expires_at` deadline).
6. Job runs `missing_purge_check/0` as a health alarm.
7. Storage objects are deleted, then DB records are removed.

### Sad Paths
- **Storage deletion failure**: Logged as a warning via `Logger.warning("ImageRetention: failed to delete storage object #{path}: #{inspect(reason)}")`. The DB record is still deleted to prevent re-processing.
- **Missing purge alarm**: If `missing_purge_check/0` finds orphaned images past expiry, an error is logged: "ALARM -- {count} orphaned image(s) past expiry".
- **Job failure**: `ImageRetentionJob` retries up to 3 times.

### Elm State Machine
N/A -- No frontend interaction for this feature.

---

## 3. API Calls

N/A -- This is a background-only process with no API endpoint.

---

## 4. Auth & Middleware Guards

N/A

---

## 5. Database Interactions

### Read: Find expired images
- **Table(s)**: `op.uploaded_images`
- **Query**: `from i in "uploaded_images", where: not is_nil(i.expires_at) and i.expires_at < ^now, select: %{id: i.id, storage_path: i.storage_path}`
- **Prefix**: `"op"`
- **Module**: `Stacks.GDPR.ImageRetention.cleanup_expired_images/0`

### Read: Find stuck images
- **Table(s)**: `op.uploaded_images`
- **Query**: `from i in "uploaded_images", where: i.status == "pending" and i.uploaded_at < ^threshold, select: %{id: i.id, storage_path: i.storage_path}`
- **Threshold**: 2 hours (`@stuck_threshold_hours 2`)
- **Prefix**: `"op"`
- **Module**: `Stacks.GDPR.ImageRetention.cleanup_stuck_images/0`

### Read: Missing purge check
- **Table(s)**: `op.uploaded_images`
- **Query**: `from i in "uploaded_images", where: i.expires_at < ^cutoff, select: %{id: i.id, storage_path: i.storage_path}`
- **Prefix**: `"op"`
- **Module**: `Stacks.GDPR.ImageRetention.missing_purge_check/0`

### Write: Delete expired image records
- **Table(s)**: `op.uploaded_images`
- **Operation**: DELETE
- **Query**: `from i in "uploaded_images", where: i.id in ^expired_ids`
- **Prefix**: `"op"`

### Write: Delete stuck image records
- **Table(s)**: `op.uploaded_images`
- **Operation**: DELETE
- **Query**: `from i in "uploaded_images", where: i.id in ^stuck_ids`
- **Prefix**: `"op"`

---

## 6. Event Flow & Lifecycle

### Events Emitted
For each deleted image record:
- **Event type**: `image.expired`
- **Aggregate**: type `"image"`, ID is the image UUID
- **Payload**: `%{}` for expired images, `%{reason: "stuck"}` for stuck images
- **Emitted by**: `Stacks.GDPR.ImageRetention.cleanup_expired_images/0` and `cleanup_stuck_images/0`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
No handlers are registered for `image.expired` in the Events Registry.

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.ImageRetentionJob`
- **Worker**: `Stacks.Workers.ImageRetentionJob`
- **Queue**: `:default`
- **Args**: None (scheduled cron job)
- **Max attempts**: 3
- **Uniqueness**: N/A (cron-scheduled)
- **What it does**:
  1. Calls `ImageRetention.cleanup_stuck_images/0`:
     - Finds images in "pending" status older than 2 hours.
     - These are images whose `IdentifyBookJob` failed or never ran.
     - Deletes storage objects via `Storage.delete_image/1`.
     - Deletes DB records.
     - Emits `image.expired` event with `reason: "stuck"` for each.
  2. Calls `ImageRetention.cleanup_expired_images/0`:
     - Finds images where `expires_at < now()`.
     - Deletes storage objects via `Storage.delete_image/1`.
     - Deletes DB records.
     - Emits `image.expired` event for each.
  3. Runs `ImageRetention.missing_purge_check/0`:
     - Finds any remaining images past their `expires_at`.
     - If any exist, logs an ERROR-level alarm.
     - Returns list of orphaned image IDs for monitoring.
  4. Logs total counts: "{stuck_count} stuck + {expired_count} expired".
- **On success**: Returns `:ok`.
- **On failure**: Logs error, returns `{:error, reason}` for retry.

---

## 8. External Service Calls

N/A -- No external services are called. Storage deletion is handled by the local storage abstraction.

---

## 9. Storage (R2 / Local)

### Delete expired/stuck images
- **Operation**: delete
- **Key pattern**: Value from `storage_path` column in `uploaded_images`
- **Module**: `Stacks.Storage.delete_image/1`
- **Backend**: `Storage.R2` (prod) / `Storage.Local` (dev) / `Storage.Mock` (test)
- **Error handling**: If storage deletion fails, a warning is logged but the DB record is still deleted to prevent the image from being retried indefinitely.

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

N/A

---

## 12. Elm Frontend State Machine (Detail)

N/A -- This is a backend-only feature with no direct frontend interaction. The Metrics Dashboard would display the count of images pending deletion, but that is rendered from a separate API endpoint.

---

## 13. Operational Metrics

- **Stuck image count**: Number of images cleaned up by `cleanup_stuck_images/0` per nightly run. Images stuck in "pending" for > 2 hours indicate `IdentifyBookJob` failures.
- **Expired image count**: Number of images cleaned up by `cleanup_expired_images/0` per nightly run. Normal operational throughput metric.
- **Orphan image count**: Number of images flagged by `missing_purge_check/0`. Any non-zero value is an ERROR-level alarm indicating images that escaped the normal cleanup pipeline.
- **Storage deletion failure rate**: Count of `Logger.warning("ImageRetention: failed to delete storage object ...")` entries. Indicates R2/local storage issues.
- **`image.expired` event count**: Total events emitted, segmented by reason (`"stuck"` vs. normal expiry).

---

## 14. Performance & Usability Metrics

- **Image retention job duration**: Wall-clock time for the full `ImageRetentionJob` run (stuck cleanup + expired cleanup + orphan check). Should complete well within the nightly cron window.
- **Cleanup batch size**: Number of images processed per run. Spikes may indicate upstream upload surges or a backlog from missed runs.
- **Time-to-purge accuracy**: Distribution of actual deletion time relative to `expires_at`. Measures how closely the system adheres to the 30-day promise.

---

## 15. Cost Tracking

- **R2 storage**: DELETE operation cost for each expired or stuck image object removed via `Storage.delete_image/1`. Cost scales linearly with the number of images cleaned up per run.
- **Neon**: Compute cost for the three read queries (stuck, expired, orphan check) plus batch DELETE operations. All queries target `op.uploaded_images` with indexed conditions (`status`, `expires_at`, `uploaded_at`).
- No external service calls beyond R2 storage deletion. No email notifications. Cost is driven primarily by R2 DELETE operations and Neon query compute.
