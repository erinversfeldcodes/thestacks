# Issue #121: E2E Test Suite — GDPR Compliance

## Summary
Comprehensive E2E test coverage for all GDPR features: data export (US-8.1), account deletion (US-8.2), consent management (US-8.3), image retention (US-8.4), and audit log (US-8.5).

## User Stories
US-8.1 (Export Personal Data), US-8.2 (Delete All Personal Data), US-8.3 (Consent Management), US-8.4 (Image Retention Policy), US-8.5 (Audit Log)

## Goal
Validate the complete GDPR compliance surface: data portability, right to erasure with cascade deletion, consent with timestamps, automated image cleanup, and immutable audit logging with encryption.

## Scope Check
- Does this issue touch more than 3 controllers? No (GDPRController handles export/delete/consent).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (all GDPR-related).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **Export**: Click "Export My Data" -> "Preparing your export..." loading state -> "Export queued" success
- **Delete**: Click "Delete My Data" -> confirmation dialog -> type "DELETE" -> submit -> "Account deletion has been queued"
- **Delete disabled**: Delete button disabled until "DELETE" typed exactly
- **Consent toggle**: Navigate to `/settings/consent` -> toggle analytics consent -> click "Save Preferences" -> "Saved!" confirmation
- **Consent error display**: Show "Could not save preferences. Please try again." on failure

### 2. Playwright Navigation & Visual Tests
- **Auth guards**: All GDPR endpoints require auth — unauthenticated users see login page
- **Consent page render**: Toggle shows current state, save button idle/loading/saved states

### 3. API Endpoint Tests
- `POST /api/gdpr/export` — 202 with `{ status: "accepted", message: "Data export has been queued." }`
- `POST /api/gdpr/export` — 401 without auth
- `DELETE /api/gdpr/account` — 202 with `{ status: "accepted", message: "Account deletion has been queued." }`
- `DELETE /api/gdpr/account` — 401 without auth
- `POST /api/gdpr/consent` with `{ consent: true }` — 200 with `consent_analytics: true` and `consent_analytics_at` timestamp
- `POST /api/gdpr/consent` with `{ consent: false }` — 200 with `consent_analytics: false`
- `POST /api/gdpr/consent` with invalid boolean — 422 `consent must be true or false`
- `POST /api/gdpr/consent` without consent param — 422 `consent parameter is required`
- `POST /api/gdpr/consent` — 401 without auth

### 4. Database Assertion Tests
- **Export**: `DataExportJob` collects user profile, bookshelves, placements (with books/editions), placement history
- **Export payload**: JSON map contains keys `exported_at`, `user`, `bookshelves`, `placements`, `placement_history`
- **Deletion cascade**: Multi transaction deletes in order: placement_history -> placements -> bookshelves -> user
- **Deletion audit**: `audit.audit_log` entry created with `action: "user.data_deleted"`, `user_id: nil`
- **Pre-deletion audit**: `audit.audit_log` entry with `action: "user.deletion_requested"` before enqueue
- **Event log preserved**: `event_log` is NOT modified during deletion (UUIDs only, no PII)
- **Consent grant**: `op.users.consent_analytics` set to `true`, `consent_analytics_at` set to current timestamp
- **Consent revoke**: `op.users.consent_analytics` set to `false`
- **Image retention — stuck**: Images in "pending" status older than 2 hours found and deleted
- **Image retention — expired**: Images past `expires_at` found and deleted
- **Image retention — orphan check**: `missing_purge_check/0` finds any remaining past-expiry images
- **Image DB records**: Deleted after storage objects removed
- **Audit log immutability**: Audit entries are INSERT-only, never updated or deleted
- **Audit log encryption**: `metadata` field encrypted via `Stacks.Vault.encrypt!/1`
- **Audit log IP hashing**: IP addresses hashed with SHA-256, never stored raw

### 5. Event Flow Tests
- Export: No events emitted (Oban job insertion only)
- Deletion: Audit log entries (not Events.emit) for `user.deletion_requested` and `user.data_deleted`
- Consent: No events emitted (timestamp on user record only)
- Image retention: `image.expired` event emitted for each deleted image (empty payload for expired, `reason: "stuck"` for stuck)
- Audit log: No events emitted (direct INSERT, terminal write destination)

### 6. Background Job Tests
- `DataExportJob` — queue `:default`, args `{ user_id }`, max_attempts 3
- `DataExportJob` — calls `GDPR.Export.export_user_data/1`, returns `:ok` on success
- `AccountDeletionJob` — queue `:default`, args `{ user_id }`, max_attempts 1 (no retries)
- `AccountDeletionJob` — cascade Multi: fetches bookshelves -> deletes history -> deletes placements -> deletes bookshelves -> deletes user -> audit log
- `AccountDeletionJob` — atomic: all steps succeed or all rolled back
- `AccountDeletionJob` — `{:error, :user_not_found}` when user does not exist
- `AccountDeletionJob` — logs failed step name on failure
- `ConfirmDeletionJob` — stub, max_attempts 3
- `ImageRetentionJob` — queue `:default`, max_attempts 3, cron-scheduled
- `ImageRetentionJob` — runs `cleanup_stuck_images/0`, `cleanup_expired_images/0`, `missing_purge_check/0` in sequence
- `ImageRetentionJob` — logs "ALARM — {count} orphaned image(s) past expiry" on orphans

### 7. External Service Tests
- N/A for export, deletion, consent, audit
- Image retention: `Storage.delete_image/1` called for each expired/stuck image
- Storage deletion failure: warning logged, DB record still deleted (prevents infinite retry)

### 8. Storage Tests
- Export: Stub — future R2 upload for user download
- Image retention: `Storage.delete_image/1` deletes objects at `storage_path` from `uploaded_images`
- Storage backend: `Storage.Mock` in test env
- R2 object deletion on image expiry verified

### 9. Cache Tests
- N/A

### 10. dbt Model Tests
- N/A for export, deletion, consent, image retention
- `stg_audit_log` staging model reads from `audit.audit_log`

### 11. Elm State Machine Tests
- Export: `UserClicksExport` -> Loading -> `GotExportResponse` -> Success (accepted)
- Deletion: `UserTypesDeleteConfirmation "DELETE"` enables button -> `UserClicksDeleteAccount` -> Loading -> Success
- Deletion: Button disabled until text exactly equals "DELETE"
- `Page.Settings.Consent` init: `{ analyticsConsent = False, saving = NotAsked }`
- `ToggleAnalytics` flips `analyticsConsent`
- `SaveConsent` -> `Api.saveConsent` -> `SaveCompleted (Ok _)` -> `saving = Success ()`
- `SaveCompleted (Err err)` -> `saving = Failure err`
- N/A for image retention (no frontend)
- N/A for audit log (no frontend page yet)

### 12. Metrics & Telemetry Tests
- `DataExportJob` enqueue count, success/failure rate
- `AccountDeletionJob` outcome: success vs failure, failed step identification
- Consent grant/revoke counts
- Image retention: stuck count, expired count, orphan count per run
- Storage deletion failure rate
- `image.expired` event counts by reason
- Audit log write throughput, action distribution, encryption overhead

## Reviewer Context
- `AccountDeletionJob` has `max_attempts: 1` — no retries for destructive operations. Failures require manual intervention.
- Event payloads contain no PII (only UUIDs), so `event_log` is not scrubbed during deletion.
- `Stacks.Vault` (Cloak encryption) requires `CLOAK_KEY` env var — tests need `.env` loaded.
- Image retention: stuck threshold is 2 hours (`@stuck_threshold_hours 2`).

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires GDPR module (Export, Deletion, Consent, ImageRetention), Audit module, GDPRController.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
