# Issue #121: E2E Test Suite — GDPR Compliance

## Summary
**Epic + v1 test-hardening.** Issue #121 hardens test coverage — and adds GDPR-specific telemetry —
for the **built v1** GDPR surface: image retention (US-8.4, end-to-end) and the backend + API layers of
data export (US-8.1), account deletion (US-8.2), consent (US-8.3, analytics), and audit-log writes
(US-8.5). The Feature-Completeness Pre-Check (below) found the originally-chartered **v2** surface is
unbuilt; it is de-scoped from this issue's deliverable and tracked as seven ordered child issues,
**#183–#189** (see Epic). No named story reaches a green audit via a feature that isn't built.

## User Stories
Validated here (v1 built surface): US-8.4 (Image Retention, end-to-end) · US-8.1 / US-8.2 / US-8.3 /
US-8.5 (backend + API only). The unbuilt UI/feature surface — US-8.1 export UI (→ #187), US-8.2 delete
UI (→ #188), US-8.3 writing-assistant consent (→ #184), US-8.5 audit-log read (→ #189), plus the shared
data-model / richer-export / deeper-cascade work (#183 / #186 / #185) — is delivered by the child
issues, NOT by #121.

## Epic — child issues (implement in this order, AFTER #121)
1. **#183 — GDPR data-model foundation** (root dependency)
2. **#184 — Writing-assistant consent (end-to-end)** — needs #183
3. **#185 — Deeper deletion cascade** — needs #183
4. **#186 — Richer export payload** — needs #183
5. **#187 — Export UI (Elm)** — independent (backend exists)
6. **#188 — Delete-account UI (Elm)** — independent (backend exists)
7. **#189 — Audit-log read API + page** — independent

Plan: `plans/121-e2e-gdpr-plan.md`.

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

## Feature-Completeness Pre-Check
<!--
Run the `feature-completeness` skill BEFORE writing any test suites for this issue. It proves each
named user story's happy path is actually BUILT end-to-end (and driven live), not merely that tests
are missing — the gate #124 lacked (US-14.3.2 was named, the audit went GREEN, yet the feature was
deferred to #173 → the #178/#179/#180/#182 cascade).

A 🟡 PARTIAL / ❌ MISSING verdict on a named story's happy path is a BLOCKING finding, NOT a
Test-Audit cell to reclassify `n/a (see #NNN)`. Resolve it exactly one of two ways: (a) build it
in-scope (add implementation phases; a design pass FIRST for non-trivial features), or (b) de-scope
it — delete the story from Summary + User Stories above and spin out a feature issue. Baseline =
"to verify"; fill verdicts + file:line evidence when this issue is picked up.
-->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.1 — Export Personal Data | `gdpr_controller.ex:export/2` (202) → `DataExportJob` → `GDPR.Export.export_user_data/2` (4/8 keys). No Elm export UI (`grep UserClicksExport` → 0). | backend 202 verified; no UI to drive | 🟡 partial | v1 backend/API tested here; export UI → **#187**, richer payload → **#186** |
| US-8.2 — Delete All Personal Data | `gdpr_controller.ex:delete_account/2` (202 + `user.deletion_requested` audit) → `AccountDeletionJob` → `Deletion.delete_user_data/1` Multi. No Elm delete UI (grep → 0). | backend 202 verified; no UI to drive | 🟡 partial | v1 backend/API + erasure invariants tested here (Ph1); delete UI → **#188**, deeper cascade → **#185** |
| US-8.3 — Consent Management | analytics: `update_consent/2` + `GDPR.Consent` + `Page.Settings.Consent` toggle — end-to-end. writing-assistant half absent (no column/worker/plug/Msg; grep → 0). | analytics drivable; writing-assistant absent | 🟡 partial | analytics tested + E2E-hardened here (Ph5); writing-assistant consent → **#184** |
| US-8.4 — Image Retention Policy | `ImageRetention.cleanup_expired/stuck` + `missing_purge_check/0`; `ImageRetentionJob` (cron). Backend-only, no UI by design. | job runs stuck→expired→orphan; storage assertions added (Ph3) | ✅ implemented | in scope — Ph2/Ph3 |
| US-8.5 — Audit Log | write path: `Audit.log/3` + DB append-only trigger (GUC-gated erasure) — strong. No read API / Elm page (grep → 0). | write path drivable + append-only enforced | 🟡 partial | write path tested here; read API + page → **#189** |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### 1. Playwright UI Tests
- **Export**: Click "Export My Data" -> "Preparing your export..." loading state -> "Export queued" success
- **Delete**: Click "Delete My Data" -> confirmation dialog -> type "DELETE" -> submit -> "Account deletion has been queued"
- **Delete disabled**: Delete button disabled until "DELETE" typed exactly
- **Consent toggle (analytics)**: Navigate to `/settings/consent` -> toggle analytics consent -> click "Save Preferences" -> "Saved!" confirmation
- **Consent toggle (writing assistant)**: Toggle AI writing assistant personalisation consent -> "Saved!" confirmation; toggling off shows description: "Your shelf and writing history are used to personalise writing suggestions. Disabling this turns off the writing assistant and deletes your session history and embeddings."
- **Consent error display**: Show "Could not save preferences. Please try again." on failure

### 2. Playwright Navigation & Visual Tests
- **Auth guards**: All GDPR endpoints require auth — unauthenticated users see login page
- **Consent page render**: Toggle shows current state, save button idle/loading/saved states

### 3. API Endpoint Tests
- `POST /api/gdpr/export` — 202 with `{ status: "accepted", message: "Data export has been queued." }`
- `POST /api/gdpr/export` — 401 without auth
- `DELETE /api/gdpr/account` — 202 with `{ status: "accepted", message: "Account deletion has been queued." }`
- `DELETE /api/gdpr/account` — 401 without auth
- `POST /api/gdpr/consent` with `{ consent: true, type: "analytics" }` — 200 with `consent_analytics: true` and `consent_analytics_at` timestamp
- `POST /api/gdpr/consent` with `{ consent: false, type: "analytics" }` — 200 with `consent_analytics: false`
- `POST /api/gdpr/consent` with `{ consent: true, type: "writing_assistant" }` — 200 with `consent_writing_assistant: true` and `consent_writing_assistant_at` timestamp
- `POST /api/gdpr/consent` with `{ consent: false, type: "writing_assistant" }` — 200, enqueues `WritingAssistantDataPurgeWorker`
- `POST /api/gdpr/consent` with invalid boolean — 422 `consent must be true or false`
- `POST /api/gdpr/consent` without consent param — 422 `consent parameter is required`
- `POST /api/gdpr/consent` — 401 without auth
- Writing assistant endpoints (`POST /api/blog/posts/:id/chat`) — 403 when `consent_writing_assistant` is false

### 4. Database Assertion Tests
- **Export**: `DataExportJob` collects user profile, bookshelves, placements (with books/editions), placement history, writing assistant sessions, turn feedback, embeddings summary (source type, title, shelf, date — no raw vectors)
- **Export payload**: JSON map contains keys `exported_at`, `user`, `bookshelves`, `placements`, `placement_history`, `writing_assistant_sessions`, `writing_assistant_feedback`, `embeddings_summary`
- **Deletion cascade**: Multi transaction deletes in order: placement_history -> placements -> bookshelves -> assistant_sessions (cascades to turn_feedback + retrieval_log) -> user-scoped embeddings -> user_book_content_access -> user
- **Deletion audit**: `audit.audit_log` entry created with `action: "user.data_deleted"`, `user_id: nil`
- **Pre-deletion audit**: `audit.audit_log` entry with `action: "user.deletion_requested"` before enqueue
- **Event log preserved**: `event_log` is NOT modified during deletion (UUIDs only, no PII)
- **Consent grant (analytics)**: `op.users.consent_analytics` set to `true`, `consent_analytics_at` set to current timestamp
- **Consent revoke (analytics)**: `op.users.consent_analytics` set to `false`
- **Consent grant (writing assistant)**: `op.users.consent_writing_assistant` set to `true`, `consent_writing_assistant_at` set to current timestamp
- **Consent revoke (writing assistant)**: `op.users.consent_writing_assistant` set to `false`, `WritingAssistantDataPurgeWorker` enqueued
- **Writing assistant purge**: Purge worker deletes `op.blog_assistant_sessions`, `op.turn_feedback` (cascade), `op.retrieval_log` (cascade), `op.embeddings WHERE user_id`, `op.user_book_content_access WHERE user_id`
- **Shared book chunks preserved**: `op.book_content_chunks` NOT deleted — contains no personal data
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
- `WritingAssistantDataPurgeWorker` — enqueued on `writing_assistant` consent revocation, deletes all user AI data, idempotent (safe to retry)
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
- `Page.Settings.Consent` init: `{ analyticsConsent = False, writingAssistantConsent = False, saving = NotAsked }`
- `ToggleAnalytics` flips `analyticsConsent`
- `ToggleWritingAssistant` flips `writingAssistantConsent`
- `SaveConsent` -> `Api.saveConsent` (with `type` param) -> `SaveCompleted (Ok _)` -> `saving = Success ()`
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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #121)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #121 covers five user stories — US-8.1 (Export
Personal Data), US-8.2 (Delete All Personal Data), US-8.3 (Consent
Management), US-8.4 (Image Retention Policy), US-8.5 (Audit Log). The
matrix is 13 layers × 5 US, happy/sad per cell. The assertion inventory
is taken from the per-US docs in `docs/user_stories/US-8.*.md` and the
per-layer Technical Requirements in `issues/121-e2e-gdpr.md`.

**GDPR is security-sensitive** — cells touching erasure completeness,
event-log immutability, audit-log immutability/encryption/IP-hashing, and
auth guards are flagged **SECURITY** inline.

---

### Feature status — CRITICAL: issue outruns the implementation

Issue #121 specifies a **v2** GDPR surface. The **v1** code that actually
exists is a strict subset. This audit baselines the implemented surface
and flags every issue requirement that has **no code behind it** as a
feature gap (a new issue under the scope-lock rule), distinct from
"feature exists, test missing".

**Implemented (verified by Read):**
- `StacksWeb.GDPRController` — `export/2` (202), `delete_account/2` (202 +
  `Audit.log(user.id, "user.deletion_requested", …)`), `update_consent/2`
  (**analytics only**, 422 invalid/missing).
- `Stacks.GDPR.Export.export_user_data/2` — user, bookshelves, placements
  (preload book:editions), placement_history. **Nothing else.**
- `Stacks.GDPR.Deletion.delete_user_data/1` — `Ecto.Multi`:
  `set_gdpr_guc` → bookshelves → bookshelf_ids → delete_history →
  delete_placements → delete_bookshelves → delete_user → audit
  (`user.data_deleted`, user_id `nil`) → reset_gdpr_guc. (`user_mfa` and
  `admin_sessions` fall away via FK cascade.)
- `Stacks.GDPR.Consent` — `grant_consent`/`revoke_consent`/`check_consent`,
  **analytics field only** (the `_feature` arg is ignored).
- `Stacks.GDPR.ImageRetention` — `cleanup_expired_images/0`,
  `cleanup_stuck_images/0`, `missing_purge_check/0`.
- `Stacks.Audit.log/3` + `log_rollback/1`; DB-level append-only trigger
  gated on `app.audit_gdpr_erasure` GUC.
- Workers: `DataExportJob` (`:default`, max_attempts 3),
  `AccountDeletionJob` (`:default`, **max_attempts 1**), `ConfirmDeletionJob`
  (stub), `ImageRetentionJob` (`:default`, max_attempts 3, cron
  `"0 2 * * *"`).
- Elm `Page.Settings.Consent` — analytics toggle + save only.
- dbt `stg_audit_log` (proto-generated).

**NOT implemented — issue requirements with no code (feature gaps):**
- **Writing-assistant consent** end to end: no `type: "writing_assistant"`
  handling in the controller, no `consent_writing_assistant[_at]` column
  (only `consent_analytics[_at]` exists in `gen/accounts/user.ex`), no
  `ToggleWritingAssistant` Msg in Elm.
- **`WritingAssistantDataPurgeWorker`** — does not exist anywhere.
- **Richer export payload** — `writing_assistant_sessions`,
  `writing_assistant_feedback`, `embeddings_summary` keys (issue §4) are
  absent from `export.ex`.
- **Deeper deletion cascade** — `op.blog_assistant_sessions`,
  `op.turn_feedback`, `op.retrieval_log`, `op.embeddings`,
  `op.user_book_content_access` (issue §5) are neither deleted nor even
  present as tables/migrations. `book_content_chunks` preservation is moot.
- **`consent_writing_assistant`-gated blog chat 403** (issue §3) — the
  `ConsentCheck` plug only knows analytics.
- **Audit-log read API + Elm audit-log page** (US-8.5 §3/§12) — write-only
  today; no `/settings/audit-log`, no list endpoint.
- **Export/Delete Elm UI** — no `UserClicksExport`, no
  `UserTypesDeleteConfirmation`/`UserClicksDeleteAccount` in `frontend/src`.

Cells whose only gap is a **feature gap** are marked ❌/⚠️ with a
`(feature not implemented)` tag so the punch list can route them to new
issues rather than to test-only work.

---

### Framework-layer summary

| Layer       | US-8.1 Export | US-8.2 Delete | US-8.3 Consent | US-8.4 Retention | US-8.5 Audit |
|-------------|---------------|---------------|----------------|------------------|--------------|
| Elixir      | ⚠️ (export payload = 4 of 8 issue keys) | ⚠️ (shelving cascade OK; audit-entry + `event_log`-preserved assertions missing; deeper cascade unimpl.) | ⚠️ (analytics solid; writing_assistant unimpl.) | ✅ (retention core well covered; storage-failure path ❌ at L6/L7) | ✅ **strong** (log + append-only trigger) |
| Elm unit    | ❌ (no export UI — feature gap) | ❌ (no delete UI — feature gap) | ✅ (SettingsTest — 5 Msgs) | n/a — backend only | n/a — no page (feature gap) |
| E2E         | ❌ (no export flow) | ❌ (no delete flow) | ⚠️ (consent smoke only; no save-result assert, no gdpr 401) | n/a — backend only | n/a — no UI |
| dbt         | n/a — operational tables | n/a — operational tables | n/a | n/a | ✅ `stg_audit_log` |
| Python      | n/a — vision uninvolved | n/a | n/a | n/a | n/a |

---

### Coverage tally

Counted per happy/sad cell across the 13 × 5 matrix (130 cells).

| Status | Count |
|--------|-------|
| ✅ STRONG | **27** |
| ⚠️ shallow | **13** |
| ❌ missing | **12** |
| n/a (higher-level / not applicable / by-design / feature-gap-with-no-surface) | **78** |

Of the 12 ❌ and 13 ⚠️, **~9 are feature gaps** (code does not exist — new
issues), the rest are test gaps against existing code. This is the
pre-implementation baseline; Issue #121's DoD requires regenerating to
0 ❌ / 0 ⚠️ after the test punch list lands and the feature gaps are
either descoped or spun into new issues.

---

### Existing test inventory (verified by Read/grep)

- `apps/core/test/stacks_web/gdpr_controller_test.exs` — 9 tests (export
  202/401, delete 202/401, consent grant/revoke/invalid/missing/401).
- `apps/core/test/stacks/gdpr_test.exs` — 13 tests (export, deletion,
  consent grant/revoke/check, image retention expired/stuck, job smoke).
- `apps/core/test/stacks/gdpr/deletion_test.exs` — 4 tests (GUC set +
  scoped, cascade of user_mfa/admin_sessions).
- `apps/core/test/stacks/gdpr/image_retention_test.exs` — 9 tests
  (expired/stuck, `image.expired` emission counts).
- `apps/core/test/stacks/audit_test.exs` — 19 tests (`log/3`,
  `log_rollback/1`, admin-call columns).
- `apps/core/test/stacks/audit_append_only_test.exs` — 6 tests (UPDATE/
  DELETE blocked, GUC-gated erasure, SET LOCAL scoping).
- `apps/core/test/stacks_web/plugs/consent_check_test.exs` — 5 tests
  (403 gate, analytics only).
- `apps/core/test/stacks/workers/{data_export,account_deletion,confirm_deletion,image_retention}_job_test.exs` — 2 + 2 + 3 + 8 tests.
- `frontend/tests/SettingsTest.elm` — 5 Consent Msg tests.
- `e2e/tests/settings.spec.ts` — 3 consent smoke tests (no export/delete).
- `dbt/models/staging/stg_audit_log.sql` + `schema.yml` — not_null/unique
  on id, not_null on action/resource_type/occurred_at, relationships
  user_id → stg_users.id.

---

### Full audit tables

#### Layer 1: API Calls

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | ✅ gdpr_controller_test.exs — "returns 202 and enqueues DataExportJob" (asserts `{status: accepted}` + `assert_enqueued`). | ✅ | ✅ gdpr_controller_test.exs — "returns 401 when not authenticated" (also serves L2). No request-body validation exists (empty body). | ✅ |
| 8.2 | ✅ gdpr_controller_test.exs — "returns 202 and enqueues AccountDeletionJob". | ✅ | ✅ gdpr_controller_test.exs — "returns 401 when not authenticated". | ✅ |
| 8.3 | ⚠️ gdpr_controller_test.exs — "returns 200 and grants consent when consent: true" + "…revokes… when consent: false" (analytics). The issue-§3 `type: "writing_assistant"` 200 variant (`consent_writing_assistant` + `_at`) has **no code** — controller ignores `type`. **(feature not implemented)** | ⚠️ | ✅ gdpr_controller_test.exs — "returns 422 when consent has an invalid value" + "returns 422 when consent parameter is missing". | ✅ |
| 8.4 | n/a — background-only feature; no API endpoint (US-8.4 §3). | n/a | n/a — same. | n/a |
| 8.5 | n/a — audit log is write-only; no read/list endpoint exists (US-8.5 §3). Issue's paginated audit API is a **feature gap** (routed to L3 DB write instead). | n/a | n/a — same. | n/a |

#### Layer 2: Auth & Middleware Guards  **(SECURITY)**

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | ✅ gdpr_controller_test.exs — authenticated conn via `auth_conn/2` reaches controller (202). | ✅ | ✅ gdpr_controller_test.exs — "returns 401 when not authenticated" (`:authenticated` pipeline rejects). | ✅ |
| 8.2 | ✅ gdpr_controller_test.exs — authenticated delete (202). | ✅ | ✅ gdpr_controller_test.exs — "returns 401 when not authenticated". | ✅ |
| 8.3 | ✅ gdpr_controller_test.exs — authenticated consent (200); consent_check_test.exs — "passes conn through when user has granted consent". | ✅ | ✅ gdpr_controller_test.exs — "returns 401 when not authenticated"; consent_check_test.exs — "halts with 403 when user has not granted consent", "…when no user is authenticated", body includes `error: consent_required`. Writing-assistant gate = **feature gap** (plug is analytics-only). | ✅ |
| 8.4 | n/a — background job, no HTTP surface. | n/a | n/a — same. | n/a |
| 8.5 | n/a — no read endpoint. DB-level append-only trigger (the real guard) is covered at L3. | n/a | n/a — same. | n/a |

#### Layer 3: Database Interactions

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | ⚠️ gdpr_test.exs — "returns a map with user data", "includes bookshelves and placements" cover user/bookshelves/placements/history. But issue-§4 export payload requires `writing_assistant_sessions`, `writing_assistant_feedback`, `embeddings_summary` keys — **not implemented** in `export.ex` (4 of 8 keys). **(feature not implemented)** | ⚠️ | ✅ gdpr_test.exs — "returns error for unknown user" (rescue → `{:error, _}`). | ✅ |
| 8.2 | ⚠️ **SECURITY / erasure completeness.** gdpr_test.exs — "removes all user data", "removes placement history for user's bookshelves"; deletion_test.exs — "deletes user_mfa and admin_sessions when user is deleted", GUC set + scoped. **Gaps:** (a) **no test asserts the `user.data_deleted` audit row** (action + `user_id: nil`) the Multi inserts; (b) issue-§5 deeper cascade (embeddings, assistant_sessions, turn_feedback, retrieval_log, user_book_content_access) is **not implemented** — those tables don't exist; (c) `book_content_chunks` preservation is untestable (no table). | ⚠️ | ✅ account_deletion_job_test.exs — "returns {:error, _} for a nonexistent user_id" (`:delete_user` → `:user_not_found`, Multi rolls back atomically). | ✅ |
| 8.3 | ✅ gdpr_test.exs — "sets consent_analytics to true and records timestamp" + "sets consent_analytics to false"; check_consent true/false/unknown. Writing-assistant columns don't exist — **feature gap**, not a test gap for the shipped field. | ✅ | n/a — invalid/missing consent is rejected before any DB write (see L1). | n/a |
| 8.4 | ✅ gdpr_test.exs + image_retention_test.exs — "deletes images past their expires_at", "deletes pending images stuck for more than 2 hours", "does not delete images not yet expired", "does not delete non-pending images regardless of age"; missing_purge_check finds orphans (image_retention_job_test.exs — "logs warning for images past expiry still in DB after cleanup"). | ✅ | ✅ image_retention_test.exs — "does not delete images not yet expired", "does not delete pending images uploaded recently". | ✅ |
| 8.5 | ✅ **SECURITY.** audit_test.exs — "inserts an audit entry successfully", "hashes the IP address before storing" (SHA-256, len 64, ≠ raw), "stores metadata in the entry", "works with nil user_id for system actions", admin-column persistence; encryption via `Stacks.Vault` exercised implicitly by every insert. audit_append_only_test.exs — "raw UPDATE … is blocked", "raw DELETE … is blocked", "trigger blocks even from privileged roles", GUC-gated erasure UPDATE/DELETE permitted, SET LOCAL scoping. | ✅ | ✅ audit_test.exs — "handles non-UUID resource_id gracefully (encode_uuid returns nil)"; log_rollback "does NOT emit telemetry when the underlying audit insert fails". | ✅ |

#### Layer 4: Event Flow & Lifecycle

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | n/a — export emits no events by design (US-8.1 §6); the only side effect is the Oban job insertion, asserted at L1/L5. | n/a | n/a — same. | n/a |
| 8.2 | ❌ **SECURITY — the headline gap.** Deletion records **audit** entries, not `Events.emit`: `user.deletion_requested` (controller, pre-enqueue) and `user.data_deleted` (inside the Multi). **Neither is asserted anywhere** (grep for both strings in `apps/core/test` → 0 hits). Separately, **no test asserts `event_log` is NOT modified during deletion** — the immutability-by-design invariant (issue §5, US-8.2 §5). This is the single most important sad-path for right-to-erasure and it is unverified. | ❌ | ❌ Same — no negative-emission / no-scrub assertion exists. | ❌ |
| 8.3 | n/a — consent emits no events by design (US-8.3 §6); state is the timestamp on the user row (asserted at L3). Writing-assistant revoke would enqueue `WritingAssistantDataPurgeWorker` — **feature gap** (see L5). | n/a | n/a — same. | n/a |
| 8.4 | ✅ image_retention_test.exs — "emits image.expired event for each deleted record" (count +2), "emits image.expired event for each stuck image deleted" (`reason: "stuck"`); image_retention_job_test.exs — "emits image.expired event with reason stuck". | ✅ | ✅ image_retention_test.exs — "returns {:ok, 0} and emits no events when nothing is expired". | ✅ |
| 8.5 | n/a — audit is a terminal write destination, emits no events (US-8.5 §6). | n/a | n/a — same. | n/a |

#### Layer 5: Background Jobs (Oban)

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | ⚠️ data_export_job_test.exs — "returns :ok for a valid user_id" (behaviour covered). But issue-§6 config (`queue :default`, `max_attempts 3`) is **unasserted**. | ⚠️ | ✅ data_export_job_test.exs — "returns {:error, _} for a nonexistent user_id" (propagates export failure for retry). | ✅ |
| 8.2 | ⚠️ **SECURITY / safety.** account_deletion_job_test.exs — "returns :ok and deletes user data for a valid user_id". But `max_attempts: 1` (no retries on a destructive op — issue §6, Reviewer Context) is **unasserted**, and "logs failed step name on failure" is unasserted. ConfirmDeletionJob stub fully covered (confirm_deletion_job_test.exs — 3 tests). | ⚠️ | ✅ account_deletion_job_test.exs — "returns {:error, _} for a nonexistent user_id" (returns `deletion failed at delete_user`, no retry). | ✅ |
| 8.3 | n/a — consent is synchronous, no Oban job. Writing-assistant revoke → `WritingAssistantDataPurgeWorker` enqueue (issue §6) is a **feature gap** (worker does not exist). | n/a | n/a — same. | n/a |
| 8.4 | ⚠️ image_retention_job_test.exs — "expires images stuck in pending past threshold", "deletes images past their expires_at", "handles no images gracefully" (perform/1 runs stuck → expired → orphan check). But issue-§6 **cron registration** (`{"0 2 * * *", ImageRetentionJob}` in `config.exs:50`) is **unasserted**. | ⚠️ | ✅ image_retention_job_test.exs — "does NOT expire pending images within threshold", "does NOT expire resolved images regardless of age", "does NOT delete images before their expires_at", "handles no images gracefully". | ✅ |
| 8.5 | n/a — audit logging is synchronous/inline (US-8.5 §7). | n/a | n/a — same. | n/a |

#### Layer 6: External Service Calls

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | n/a — export reads the local DB only (US-8.1 §8). | n/a | n/a — same. | n/a |
| 8.2 | n/a — deletion is DB-only; images are handled by US-8.4 (US-8.2 §8). | n/a | n/a — same. | n/a |
| 8.3 | n/a — consent is DB-only (US-8.3 §8). | n/a | n/a — same. | n/a |
| 8.4 | ⚠️ `Storage.delete_image/1` is invoked per expired/stuck image via `Storage.Mock`, but **no test asserts the call happens** (no spy/expectation on the storage backend; deletion counts don't distinguish DB-delete from storage-delete). | ⚠️ | ❌ issue-§7 "storage deletion failure → warning logged, DB record still deleted" is **unasserted** — `delete_storage_objects/1`'s `{:error, reason}` warning branch (image_retention.ex:147) has no test. **Key sad-path for the 30-day promise.** | ❌ |
| 8.5 | n/a — audit is a local write; encryption/hashing are in-process, not external services (US-8.5 §8). | n/a | n/a — same. | n/a |

#### Layer 7: Storage (R2 / Local)

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | n/a — export R2 upload is an explicit stub / future work (US-8.1 §9). | n/a | n/a — same. | n/a |
| 8.2 | n/a — deletion performs no storage ops (US-8.2 §9). | n/a | n/a — same. | n/a |
| 8.3 | n/a — no storage in the consent path. | n/a | n/a — same. | n/a |
| 8.4 | ⚠️ `Storage.Mock` is the test backend; object deletion at `storage_path` happens but is **not asserted** (same gap as L6 happy — no assertion that the R2/Mock object is removed). | ⚠️ | ❌ Same storage-failure branch as L6 sad — DB-record-still-deleted-on-storage-error is unverified. | ❌ |
| 8.5 | n/a — audit has no storage interaction. | n/a | n/a — same. | n/a |

#### Layer 8: Cache Interactions

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | n/a — issue §9 marks cache N/A; export has no cache path. | n/a | n/a — same. | n/a |
| 8.2 | n/a — no explicit cache invalidation on deletion (US-8.2 §10); user-keyed caches expire naturally. | n/a | n/a — same. | n/a |
| 8.3 | n/a — no cache in the consent path (US-8.3 §10). | n/a | n/a — same. | n/a |
| 8.4 | n/a — retention has no cache interaction (US-8.4 §10). | n/a | n/a — same. | n/a |
| 8.5 | n/a — audit has no cache interaction (US-8.5 §10). | n/a | n/a — same. | n/a |

#### Layer 9: dbt Model Dependencies

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | n/a — export reads operational tables, not dbt models (US-8.1 §11). | n/a | n/a — same. | n/a |
| 8.2 | n/a — deletion operates on operational tables; warehouse anonymisation is separate (US-8.2 §11). | n/a | n/a — same. | n/a |
| 8.3 | n/a — consent has no dbt dependency (US-8.3 §11). | n/a | n/a — same. | n/a |
| 8.4 | n/a — retention has no dbt dependency (US-8.4 §11). | n/a | n/a — same. | n/a |
| 8.5 | ✅ `dbt/models/staging/stg_audit_log.sql` exists (proto-generated), reading `audit.audit_log`. `schema.yml` tests: `not_null` + `unique` on `id`, `not_null` on `action`/`resource_type`/`occurred_at`, `relationships` `user_id → stg_users.id` (compiled test artifacts present). | ✅ | n/a — no constrained-enum column on `stg_audit_log` (`action` is free-form text); the one FK worth testing (`user_id`) is already covered by the `relationships` test in the happy cell. | n/a |

#### Layer 10: Elm Frontend State Machine

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1 | ❌ **(feature not implemented).** Issue §11 wants `UserClicksExport → Loading → GotExportResponse → Success`. No export Msg/flow exists in `frontend/src` (grep `UserClicksExport` → 0 hits); `Page.Settings.Consent` has no export button. | ❌ | ❌ Same — no export failure-state handling exists. | ❌ |
| 8.2 | ❌ **(feature not implemented).** Issue §11 wants `UserTypesDeleteConfirmation "DELETE"` enabling the button → `UserClicksDeleteAccount → Loading → Success`. No such Msg/flow in `frontend/src` (grep → 0 hits). | ❌ | ❌ Same — no "button disabled until exactly DELETE" test because the UI doesn't exist. | ❌ |
| 8.3 | ✅ SettingsTest.elm — "ToggleAnalytics flips analyticsConsent", "SaveConsent with token sets saving to Loading", "SaveConsent without token leaves saving as NotAsked", "SaveCompleted Ok sets saving to Success". Init `{analyticsConsent = False, saving = NotAsked}` matches. `ToggleWritingAssistant` (issue §11) = **feature gap** (Msg does not exist). | ✅ | ✅ SettingsTest.elm — "SaveCompleted Err sets saving to Failure". | ✅ |
| 8.4 | n/a — backend-only feature, no frontend (US-8.4 §12). | n/a | n/a — same. | n/a |
| 8.5 | n/a — no audit-log Elm page exists (US-8.5 §12 — "Not yet implemented"). **(feature gap, but issue §11 marks N/A)**. | n/a | n/a — same. | n/a |

#### Layer 11: Operational Metrics

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1–8.5 | n/a — per-route latency and Oban job counts are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy) plus automatic Phoenix-endpoint and Oban telemetry. Per project convention, per-US repetition of firing tests adds no guarantee. | n/a | ⚠️ Issue §12 asks for **GDPR-specific instrumentation** — `DataExportJob`/`AccountDeletionJob` outcome counts (incl. failed-step id), consent grant/revoke counts, image stuck/expired/orphan counts, `image.expired`-by-reason, audit-log throughput/encryption overhead. **None is instrumented** (grep of `observability_telemetry_test.exs` for gdpr/export/deletion/consent/image → 0 hits). Needs a decision: instrument + add firing tests (pattern: `upload_telemetry_test.exs`), or descope §12 to the SLO gate. Partly blocked on instrumentation (feature gap). | ⚠️ |

#### Layer 12: Performance & Usability Metrics

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1–8.5 | n/a — covered by the SLO gate, not unit tests; in-test SLA bounds (export generation time, deletion cascade time, consent save latency) are an anti-pattern under variable CI timing. | n/a | n/a — same. | n/a |

#### Layer 13: Cost Tracking

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 8.1–8.3, 8.5 | n/a — export/deletion/consent/audit are DB-only with no external per-call spend (US-8.* §15); Neon compute is a deploy-time cost-dashboard concern, nothing to record in `BudgetTracker`. | n/a | n/a — same. | n/a |
| 8.4 | n/a — R2 DELETE cost per image is a dashboard/cost-model concern (US-8.4 §15); there is no per-call `BudgetTracker.record_cost` in the retention path and none is required. | n/a | n/a — same. | n/a |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline). `[FG]` = feature
gap (code does not exist — spin a new issue per scope-lock); `[TEST]` =
feature exists, test missing (in scope for #121).

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | **L4 US-8.2 happy** — **SECURITY, top priority** `[TEST]` | Assert the two audit rows deletion writes: `user.deletion_requested` (controller, before enqueue) with `user_id` = the user; and `user.data_deleted` (inside the Multi) with **`user_id: nil`** + `resource_type: "user"`, `resource_id: <deleted user id>`. Query `audit.audit_log` after the flow. | `apps/core/test/stacks_web/gdpr_controller_test.exs` (requested) + `apps/core/test/stacks/gdpr/deletion_test.exs` (data_deleted) |
| 2 | **L4 US-8.2 sad** — **SECURITY, erasure invariant** `[TEST]` | Assert **`event_log` is NOT modified during deletion** — snapshot `op.event_log` row count/ids before `delete_user_data/1`, assert unchanged after. Encodes the "payloads are UUID-only, nothing to scrub" design contract. | `apps/core/test/stacks/gdpr/deletion_test.exs` |
| 3 | L1/L3 US-8.1 happy `[FG]` | Export payload completeness: `writing_assistant_sessions`, `writing_assistant_feedback`, `embeddings_summary` (source type/title/shelf/date, **no raw vectors**) keys — requires implementing the export extension **and** the underlying tables. New issue. | `apps/core/lib/stacks/gdpr/export.ex` + new migrations → then `gdpr_test.exs` |
| 4 | L3 US-8.2 happy `[FG]` — **SECURITY, erasure completeness** | Deeper deletion cascade: `op.embeddings`, `op.blog_assistant_sessions`, `op.turn_feedback`, `op.retrieval_log`, `op.user_book_content_access` deleted; `op.book_content_chunks` preserved. Tables don't exist yet. New issue (blocks the writing-assistant feature). | `apps/core/lib/stacks/gdpr/deletion.ex` + migrations → then `deletion_test.exs` |
| 5 | L1/L2/L3/L5/L10 US-8.3 `[FG]` | Writing-assistant consent end to end: `type` param in controller, `consent_writing_assistant[_at]` columns, `ConsentCheck` writing_assistant gate (403 on blog chat), `WritingAssistantDataPurgeWorker` (enqueued on revoke, idempotent), `ToggleWritingAssistant` Elm Msg. New issue. | `gdpr_controller.ex`, `consent.ex`, `plugs/consent_check.ex`, new worker, `Consent.elm` → then tests |
| 6 | L1 US-8.3 happy `[TEST]` | Once #5 lands: consent endpoint 200 for `type: "writing_assistant"` grant (`consent_writing_assistant: true` + `_at`) and revoke (enqueues purge worker). | `apps/core/test/stacks_web/gdpr_controller_test.exs` |
| 7 | L5 US-8.1 happy `[TEST]` | Assert `DataExportJob` config: `queue: :default`, `max_attempts: 3` (via `__opts__`/job struct). | `apps/core/test/stacks/workers/data_export_job_test.exs` |
| 8 | L5 US-8.2 happy `[TEST]` — **SECURITY/safety** | Assert `AccountDeletionJob` has **`max_attempts: 1`** (destructive, no retries) and logs the failed step name on `{:error, step, …}`. | `apps/core/test/stacks/workers/account_deletion_job_test.exs` |
| 9 | L5 US-8.4 happy `[TEST]` | Assert `ImageRetentionJob` is registered in the Oban cron plugin (`{"0 2 * * *", ImageRetentionJob}` in `config.exs`). | `apps/core/test/stacks/workers/image_retention_job_test.exs` |
| 10 | L6/L7 US-8.4 happy `[TEST]` | Assert `Storage.delete_image/1` is actually invoked (per expired + per stuck image) — spy/expectation on the storage backend, not just DB-count. | `apps/core/test/stacks/gdpr/image_retention_test.exs` |
| 11 | L6/L7 US-8.4 sad `[TEST]` — **retention integrity** | Assert storage-failure resilience: when `Storage.delete_image/1` returns `{:error, _}`, a warning is logged **and the DB record is still deleted** (`delete_storage_objects/1` error branch, image_retention.ex:147). | `apps/core/test/stacks/gdpr/image_retention_test.exs` |
| 12 | L10 US-8.1 `[FG]` | Elm export flow: `UserClicksExport → Loading → GotExportResponse (Ok/Err)` on the Settings page, wired to `POST /api/gdpr/export`. New issue (UI does not exist). | `frontend/src/Page/Settings/*` → then a program/unit test |
| 13 | L10 US-8.2 `[FG]` | Elm delete flow: `UserTypesDeleteConfirmation` enabling the button only on exact `"DELETE"`, `UserClicksDeleteAccount → Loading → Success`, farewell/logout OutMsg. New issue (UI does not exist). | `frontend/src/Page/Settings/*` → then a test |
| 14 | E2E US-8.1/8.2 `[FG]` | Playwright: Export ("Preparing your export…" → "Export queued") and Delete (confirm dialog → type DELETE → "Account deletion has been queued", button disabled until exact match) UI flows; plus auth-guard checks that `/api/gdpr/*` return 401 unauthenticated (settings.spec.ts covers `/api/settings/*` 401 but **not** gdpr). Blocked on #12/#13 for the UI portions; the 401 API checks can land now. | `e2e/tests/settings.spec.ts` (or new `gdpr.spec.ts`) |
| 15 | E2E US-8.3 `[TEST]` | Strengthen consent E2E beyond smoke: assert "Saved!" success text after save, and the "Could not save preferences…" error path on failure (settings.spec.ts currently only asserts no `.error` element appears). | `e2e/tests/settings.spec.ts` |
| 16 | L11 US-8.* sad `[FG/decision]` | Decide + implement GDPR telemetry (export/deletion outcomes incl. failed-step, consent grant/revoke, image stuck/expired/orphan, `image.expired`-by-reason, audit throughput) with firing tests (pattern: `upload_telemetry_test.exs`) — **or** formally descope issue §12 to the SLO gate and reclassify n/a. Partly blocked on instrumentation. | `apps/core/lib/stacks/**` + new telemetry test, or a scope note |

---

### Verdict

**Baseline established — audit NOT yet resolved, and the issue materially
outruns the implementation.** State across the 13-layer × 5-US matrix
(130 happy/sad cells):

- **27 ✅ STRONG** — the implemented v1 core is genuinely well covered:
  API 202/401 for export & delete, consent grant/revoke/422s, the full
  image-retention DB matrix + `image.expired` emission, and an
  **excellent** audit surface (log/3, IP-hashing, encryption, and a
  DB-level append-only trigger with GUC-gated erasure and SET LOCAL
  scoping).
- **13 ⚠️ shallow** — export payload (4 of 8 issue keys), deletion cascade
  (shelving-only + unasserted audit/event-log invariants), analytics-only
  consent, unasserted job config (`max_attempts`, cron), storage-call
  assertions, and missing GDPR telemetry.
- **12 ❌ missing** — the **event-log / audit-entry erasure invariants**
  (US-8.2 L4, SECURITY), the storage-failure retention path (US-8.4
  L6/L7), and the entirely absent Export/Delete Elm + E2E flows.
- **78 n/a** — external services, cache, dbt (except audit), performance,
  cost, and the many background/no-UI combinations, each with an inline
  rationale.

**Headline findings (highest-value gaps):**
1. **Erasure invariants are unverified (SECURITY).** Nothing asserts that
   `delete_user_data/1` writes the `user.data_deleted` audit row
   (`user_id: nil`) or the `user.deletion_requested` pre-audit, and —
   critically — **nothing asserts `event_log` is left untouched** during
   erasure. The immutable-event-log-except-GDPR-PII contract is documented
   in code but has zero test teeth (punch #1, #2).
2. **Erasure is incomplete vs. the issue (SECURITY).** The deletion Multi
   only reaches shelving tables + user; the issue's writing-assistant /
   embeddings / retrieval-log / content-access cascade — and the whole
   writing-assistant consent surface — **does not exist in code**
   (punch #4, #5). Right-to-erasure currently cannot cover data the issue
   says it must, because that data model isn't built.
3. **Export payload is a 4-of-8-key subset** and the **entire Export/Delete
   Elm + E2E journey is unbuilt** (punch #3, #12, #13, #14). US-8.3
   (consent) is the only fully-wired UI, and even it lacks writing-assistant
   and save-result E2E assertions.

**Test-runner totals at baseline (GDPR-related):** Elixir ~65 tests across
9 files (all passing), Elm 5 Consent Msg tests, Playwright 3 consent smoke
tests, dbt 6 generic column tests on `stg_audit_log`. **Punch list: 16
items** — of which **~9 are feature gaps** requiring new issues (writing-
assistant consent, deeper cascade, richer export, export/delete UI, audit-
log read API, GDPR telemetry) and **7 are in-scope test additions** for
Issue #121 (audit-entry + event-log invariants, storage-failure path,
job-config assertions, cron registration, consent E2E hardening).
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires GDPR module (Export, Deletion, Consent, ImageRetention), Audit module, GDPRController.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
