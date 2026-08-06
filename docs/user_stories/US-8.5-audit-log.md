# US-8.5 — Audit Log

## 1. User Story

> **As a** user, **I want to** view an audit log of all data access events **so that** I have full transparency into how my data has been used.

The user navigates to Settings > Audit Log. A chronological list of significant actions on their account is displayed, most recent first.

**What they see on the page (as shipped):**
- A page headed "Audit Log", subtitled "A record of significant actions on your account, most recent first."
- A ledger-style table with **three** columns: Action, Resource, When (`frontend/src/Page/Settings/AuditLog.elm:99-109`, rows at `:112-119`). The Action cell shows the raw action string (e.g. `user.deletion_requested`); Resource shows the resource type; When shows the `occurred_at` timestamp as the server rendered it.
- Whatever the sidebar calls it: the Settings sidebar labels this "Audit Log" (`frontend/src/Page/Settings.elm:77`) while the user-menu shortcut labels the same route "Activity Log" (`frontend/src/Main.elm:3944`) — two names for one page.
- With no entries: "No audit entries yet." (`AuditLog.elm:94-96`). While loading: "Loading your audit log...". On failure: "Failed to load your audit log. Please try again."
- Never an IP address. The stored column holds a SHA-256 hash and is excluded at the SQL level, not merely omitted from the view.

**What the original story asked for and the page does not yet do** — recorded here so an audit does not read the shipped page as complete:
- **No data-classification tiers.** The four-tier classification is not carried on the audit row, so the table cannot show it.
- **No human-readable description.** The Action column shows the raw dotted action string; there is no copy layer turning `user.deletion_requested` into a sentence.
- **No search.** No filter input exists.
- **No pagination controls.** The endpoint is fully paginated and the response carries `total`/`page`/`per_page`, but the client asks for page 1 only — see §12.
- **Metadata is decrypted, sent, and then dropped.** `render_entry/1` includes the decrypted `metadata` map, but `auditLogEntryDecoder` (`frontend/src/Api.elm:2006-2013`) has no `metadata` field, so it never reaches the page. This is the wrong direction for a GDPR surface: personal data is being decrypted and put on the wire for a client that discards it. Either render it or stop sending it.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to Settings > Audit Log (`/settings/audit-log`, `frontend/src/Navigation/Route.elm:84` parser, `:166` path).
2. `Page.Settings.AuditLog.init` fires `Api.getAuditLog` immediately; the page shows "Loading your audit log...".
3. The first page of 25 entries renders newest-first as an Action / Resource / When table.
4. That is the end of the flow. There is no next-page control and no search, so the reader sees their 25 most recent actions and nothing further.

### Sad Paths
- **Not authenticated**: rejected by the auth pipeline. In-SPA, a token-less init leaves `entries = NotAsked` and renders nothing at all (`AuditLog.elm:47-48`, `:84-85`) — a blank panel rather than a prompt.
- **Session expired mid-load**: a 401 returns the `SessionExpired` OutMsg, so the reader is taken to the sign-in card rather than shown "Failed to load".
- **No audit entries**: "No audit entries yet." — the empty state is a sentence, not an empty table.
- **A single corrupt row**: decryption and JSON failures on one row's metadata are swallowed to an empty map (`apps/core/lib/stacks/audit.ex:241-244`) so one bad row cannot break the whole listing.
- **Absurd page number**: an offset large enough to overflow bigint returns an empty page rather than a 500 (`audit.ex:173-180`).

### Elm State Machine
- **Page module**: `Page.Settings.AuditLog` (`frontend/src/Page/Settings/AuditLog.elm`) -- a dedicated, read-only page.
- **Model fields involved**: `entries : RemoteData Http.Error AuditLogResponse` (`AuditLog.elm:25-27`). One field, because the page has exactly one thing to say.
- **Msg flow**: `init token -> Api.getAuditLog -> AuditLogReceived (Result Http.Error AuditLogResponse)` (`AuditLog.elm:39-48`, `:54`).
- **RemoteData states**: NotAsked (no token) -> Loading -> Success/Failure.
- **OutMsg**: `NoOut | SessionExpired` -- a 401 hands the expiry to `Main` rather than rendering a page-local error (`AuditLog.elm:60-61`; see US-14.3.2).

---

## 3. API Calls

### `GET /api/settings/audit-log`
- **Auth**: Required (JWT Bearer token)
- **Pipeline**: `:api`, `:authenticated` (`apps/core/lib/core_web/router.ex:262`)
- **Controller**: `StacksWeb.AuditLogController.index/2`
- **Query params**: `page` (default 1), `per_page` (default 25), both parsed leniently -- a non-numeric value falls back to the default rather than erroring.
- **Response (success)**: `{ entries: [{ id, action, resource_type, resource_id, occurred_at, metadata }], total, page, per_page }` -- HTTP 200
- **Client**: `Api.getAuditLog` (`frontend/src/Api.elm:2027-2036`). ⚠️ It requests `…/audit-log?page=1` **hardcoded** -- see the residue note in §12.
- **Deliberate omission**: `ip_address` is never selected or rendered. The column holds a SHA-256 hash, and a hashed IP is still a correlatable identifier, so the read path excludes it at the SQL level (`apps/core/lib/stacks/audit.ex:182-183`) rather than trusting the serialiser to drop it -- `render_entry/1` (`audit_log_controller.ex:42-51`) whitelists display-safe fields as a second wall.

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline` (`:authenticated`) -> `RequireConfirmedEmail` -> controller action.
- **Visibility checks**: a user sees only their own entries. This is not a filter the caller can influence: the query is keyed by `Guardian.Plug.current_resource(conn).id` (`audit_log_controller.ex:25`, `:28`) and there is no `user_id` parameter to tamper with.
- **Age gate**: N/A
- **Ownership checks**: structural, per above -- `Audit.list_for_user/2` takes a `user_id` and `WHERE user_id = $1` is unconditional (`audit.ex:191`).

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

### Read: List a user's own entries (the page)
- **Table(s)**: `audit.audit_log`
- **Module**: `Stacks.Audit.list_for_user/2` (`apps/core/lib/stacks/audit.ex:166`)
- **Query**: a raw `Repo.query/2` pair — `SELECT COUNT(*) … WHERE user_id = $1` for the total, then `SELECT id, action, resource_type, resource_id, metadata, occurred_at … WHERE user_id = $1 ORDER BY occurred_at DESC, id DESC LIMIT $2 OFFSET $3` (`audit.ex:188-194`). Raw SQL because the table is written with `insert_all` against a prefixed schema and has no Ecto schema module.
- **`id` in the ORDER BY is load-bearing**: transactional audit writes can collide at microsecond resolution on `occurred_at`, and without a tiebreaker those rows order nondeterministically across page boundaries — duplicating or skipping entries between page 1 and page 2.
- **`ip_address` is not selected.** The exclusion lives in the query, so no future serialiser change can leak it.
- **Decode**: `decode_read_row/1` (`audit.ex:220-229`) loads binary UUIDs back to strings, converts the naive timestamp to UTC, and decrypts `metadata`.
- **Pagination guards**: `normalise_page/1` and `clamp_per_page/1` bound the inputs before they reach SQL.
- **Telemetry**: `[:stacks, :gdpr, :audit, :read]` fires once per listing (`audit.ex:207`), deliberately **untagged** — "who read the audit log" must not itself become a personal-data trail in a warehouse-adjacent sink.

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
- **Consumer**: Metrics Dashboard GDPR section. The user-facing audit page does **not** read a dbt model — it queries `audit.audit_log` directly (§5), so the page is never stale behind a refresh.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.SettingsAuditLog` (`frontend/src/Navigation/Route.elm:32`; parser `:84`, path `:166`)
- **URL**: `/settings/audit-log`
- **Public or authenticated**: Authenticated
- **Reachable from**: the Settings sidebar under the "Your data" group (`frontend/src/Page/Settings.elm:77`) and the user menu's settings links (`frontend/src/Main.elm:3944`).

### Init
- **`initPage` branch**: `SettingsAuditLog -> AuditLog.init maybeToken` (`Main.elm:1139-1144`).
- **API calls on init**: `Api.getAuditLog token AuditLogReceived` when a token is present; none otherwise.
- **Initial model state**: `entries = Loading` with a token, `NotAsked` without.

### Update cycle

| Msg | Model change | OutMsg |
|-----|-------------|--------|
| `AuditLogReceived (Ok response)` | `entries = Success response` | `NoOut` |
| `AuditLogReceived (Err err)` when `Api.isUnauthorized err` | unchanged | `SessionExpired` |
| `AuditLogReceived (Err err)` otherwise | `entries = Failure err` | `NoOut` |

That is the whole update function (`AuditLog.elm:51-64`) — the page is read-only and has no other interaction.

### View
- **Rendered by**: `view` / `viewContent` / `viewRow` (`AuditLog.elm:71-119`).
- **Key elements**: `h1` "Audit Log"; a subtitle; then per state — "Loading your audit log...", "Failed to load your audit log. Please try again.", "No audit entries yet.", or the three-column table.
- **CSS classes**: `page`, `page--settings`, `page__title`, `settings-section__desc`, `audit-log__empty`, `audit-log__table`, `audit-log__row`, `audit-log__action`, `audit-log__resource`, `audit-log__when`, `audit-log__timestamp`, plus `loading` / `error`.
- **ARIA attributes**: none. A `role="status"` on the loading/empty region would match how the rest of the settings surface announces state.

### ⚠️ Residue: pagination is server-only
The endpoint pages properly and the response type carries `total`, `page`, and `perPage` (`frontend/src/Api.elm:1998-2003`) — but `Api.getAuditLog` hardcodes `?page=1` (`Api.elm:2035`) and the page renders no next/previous control. So `total` is decoded and never shown, and a user with more than 25 audited actions cannot reach the rest of their own record. The parameterised backend is not the gap; the client's single fixed request is.

---

## 13. Operational Metrics

- **Audit log write throughput**: INSERT rate into `audit.audit_log`, segmented by `action` type (`user.deletion_requested`, `user.data_deleted`, future action types). Baseline for capacity planning.
- **Audit action distribution**: Breakdown of entries by `action` field. Identifies which operations are most frequently audited.
- **Encryption overhead**: Track `Stacks.Vault.encrypt!/1` call frequency and any encryption failures (caught by the `rescue` block in `Audit.log/3`).
- **Audit entry volume per user**: Count of audit entries grouped by `user_id`. Identifies users with unusually high audit activity.

---

## 14. Performance & Usability Metrics

- **Audit log write latency**: Time for a single `Audit.log/3` call, including UUID binary encoding, IP hashing (SHA-256), metadata encryption (Cloak), and the `Repo.insert_all/3` operation. This runs inline in the calling function, so latency directly impacts the parent operation.
- **Audit log read latency**: two queries per page load — a `COUNT(*)` over the user's rows plus the windowed `SELECT`. The count is the one that degrades as the table grows monotonically, and it is paid on every page load to populate a `total` the page does not currently display (§12). Cloak decryption is paid per row for a `metadata` map the client discards.
- **Audit read volume**: `stacks_gdpr_audit_read_count_total` (from `[:stacks, :gdpr, :audit, :read]`, `apps/core/lib/stacks/audit.ex:207`) counts listings. Untagged by design, so it measures load, not who.
- **dbt staging model refresh time**: Duration of `stg_audit_log` incremental refresh. Grows with audit log volume.

---

## 15. Cost Tracking

- **Neon**: Compute cost for INSERT operations into `audit.audit_log`. Each entry involves UUID binary encoding, SHA-256 hashing, and Cloak encryption before write. The table is append-only (never updated or deleted except for GDPR erasure), so storage grows monotonically.
- **Neon storage**: Long-term storage cost for the `audit.audit_log` table. Encrypted metadata blobs may be larger than plaintext equivalents. Monitor table size growth rate.
- No external service calls. All operations are local DB writes with in-process encryption. Cost is dominated by Neon compute and storage.
