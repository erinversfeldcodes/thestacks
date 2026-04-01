# US-8.5 — Audit Log

## 1. User Story

> **As a** user, **I want to** view an audit log of all data access events **so that** I have full transparency into how my data has been used.

The user navigates to Settings > Audit Log. A chronological list of data access events is displayed.

**What they see on the page:**
- A ledger-style table with columns: timestamp, event type (data export, review fetch, price scrape, admin access, etc.), data category affected, and a brief description.
- Data classification tiers are indicated: public book metadata, personal shelf data, sensitive KYC/payment data, external personal data (e.g., Reddit usernames referenced in reviews).
- External personal data (such as Reddit usernames encountered during review aggregation) is shown as pseudonymised in analytics contexts.
- The log is paginated and searchable.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to Settings > Audit Log.
2. System displays paginated list of audit entries for the user.
3. User can page through entries, viewing timestamp, action, resource type, and metadata.

### Sad Paths
- **Not authenticated**: Rejected by auth pipeline.
- **No audit entries**: Empty table with a reassuring message.

### Elm State Machine
- **Page module**: Not yet implemented as a dedicated Elm page.
- **Model fields involved**: Paginated list of audit entries.
- **Msg flow**: `LoadAuditLog -> GotAuditEntries (page)`
- **RemoteData states**: NotAsked -> Loading -> Success/Failure

---

## 3. API Calls

No dedicated API endpoint for listing audit entries exists yet. The audit log is currently write-only from the backend.

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): Would require `:api`, `:authenticated` pipeline.
- **Visibility checks**: Users should only see their own audit entries.
- **Age gate**: N/A
- **Ownership checks**: Filter by `user_id` from authenticated session.

---

## 5. Database Interactions

### Write: Insert audit entry
- **Table(s)**: `audit.audit_log`
- **Operation**: INSERT-only (never update or delete)
- **Schema**: Raw table access via `Repo.insert_all/3` with prefix `"audit"`
- **Fields**:
  - `id` -- UUID (generated, stored as binary)
  - `user_id` -- UUID of the acting user (binary-encoded, `nil` for system actions like post-deletion audit)
  - `action` -- string describing the action (e.g., `"user.data_deleted"`, `"user.deletion_requested"`)
  - `resource_type` -- type of resource acted on (e.g., `"user"`, `"book"`)
  - `resource_id` -- UUID of the affected resource (binary-encoded)
  - `ip_address` -- SHA-256 hash of the raw IP string (never stores raw IP)
  - `metadata` -- arbitrary map, JSON-encoded then encrypted via `Stacks.Vault.encrypt!/1`
  - `occurred_at` -- `DateTime.utc_now()` at time of logging
- **Module**: `Stacks.Audit.log/3`

### Security measures in `Stacks.Audit`:
- IP addresses are hashed with SHA-256 before storage (`hash_ip/1`).
- Metadata is encrypted via `Stacks.Vault` (Cloak encryption) before storage.
- UUIDs are binary-encoded via `Ecto.UUID.dump/1`.
- The function uses `rescue` to catch and return errors rather than raising.

### Known audit actions in the codebase:
- `"user.deletion_requested"` -- logged by `GDPRController.delete_account/2` before enqueuing deletion
- `"user.data_deleted"` -- logged inside the deletion `Ecto.Multi` after all data is removed

---

## 6. Event Flow & Lifecycle

### Events Emitted
The audit module does not emit events via `Events.emit/1`. It is a direct INSERT operation.

### Event Handlers Triggered
N/A -- The audit log is a terminal write destination, not an event source.

---

## 7. Background Jobs (Oban)

N/A -- Audit logging is synchronous. It runs inline within the calling function (controller or Multi step).

---

## 8. External Service Calls

N/A

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

- **Model**: `stg_audit_log` (staging model)
- **Trigger**: N/A -- incremental or scheduled refresh
- **Materialisation**: View or incremental
- **Consumer**: Metrics Dashboard GDPR section, potential future audit log UI

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: Not yet implemented
- **URL**: `/settings/audit-log` (planned)
- **Public or authenticated**: Authenticated

### Init
- Not yet implemented. Would load paginated audit entries on init.

### Update cycle
- Not yet implemented.

### View
- Not yet implemented. Would render a ledger-style table with columns: timestamp (occurred_at), action, resource_type, and decrypted metadata summary.
- **CSS classes**: Planned to use settings page and table styling.

---

## 13. Operational Metrics

- **Audit log write throughput**: INSERT rate into `audit.audit_log`, segmented by `action` type (`user.deletion_requested`, `user.data_deleted`, future action types). Baseline for capacity planning.
- **Audit action distribution**: Breakdown of entries by `action` field. Identifies which operations are most frequently audited.
- **Encryption overhead**: Track `Stacks.Vault.encrypt!/1` call frequency and any encryption failures (caught by the `rescue` block in `Audit.log/3`).
- **Audit entry volume per user**: Count of audit entries grouped by `user_id`. Identifies users with unusually high audit activity.

---

## 14. Performance & Usability Metrics

- **Audit log write latency**: Time for a single `Audit.log/3` call, including UUID binary encoding, IP hashing (SHA-256), metadata encryption (Cloak), and the `Repo.insert_all/3` operation. This runs inline in the calling function, so latency directly impacts the parent operation.
- **Audit log query latency** (future): When the paginated read API is implemented, measure query time for `audit.audit_log` filtered by `user_id` with pagination. Metadata decryption cost will scale with page size.
- **dbt staging model refresh time**: Duration of `stg_audit_log` incremental refresh. Grows with audit log volume.

---

## 15. Cost Tracking

- **Neon**: Compute cost for INSERT operations into `audit.audit_log`. Each entry involves UUID binary encoding, SHA-256 hashing, and Cloak encryption before write. The table is append-only (never updated or deleted except for GDPR erasure), so storage grows monotonically.
- **Neon storage**: Long-term storage cost for the `audit.audit_log` table. Encrypted metadata blobs may be larger than plaintext equivalents. Monitor table size growth rate.
- No external service calls. All operations are local DB writes with in-process encryption. Cost is dominated by Neon compute and storage.
