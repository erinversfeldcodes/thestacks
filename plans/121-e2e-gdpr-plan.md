# Plan: E2E Test Suite — GDPR Compliance (epic + v1 test-hardening)
**Issue**: #121
**Created**: 2026-07-12
**Status**: Approved

## Context
Issue #121 was chartered to add comprehensive GDPR E2E/test coverage for five user stories
(US-8.1 export, US-8.2 delete, US-8.3 consent, US-8.4 image retention, US-8.5 audit log). The
Feature-Completeness Pre-Check (run during planning) confirmed the issue **materially outruns the
implementation**: only a **v1** subset is built. #121 therefore becomes an **epic** — it hardens
tests (and adds GDPR telemetry) for the built v1 surface, and de-scopes the unbuilt v2 surface into
seven ordered child issues (#183–#189) that it tracks.

## Research Summary
Basis: the issue's own Read-verified Test Audit (2026-07-08), re-confirmed 2026-07-12 (nothing built
since — export/delete Elm UI, writing-assistant consent, and audit-log read all return 0 grep hits).

**Built (v1):** `GDPRController` (export 202, delete_account 202 + `user.deletion_requested` audit,
update_consent analytics-only + 422s); `GDPR.Export` (user/bookshelves/placements/history — 4/8 issue
payload keys); `GDPR.Deletion` Multi (GUC → shelving cascade → user → `user.data_deleted` audit,
user_id nil); `GDPR.Consent` (analytics field only); `GDPR.ImageRetention` (expired/stuck/orphan);
`Audit.log/3` + DB append-only trigger (GUC-gated erasure); workers `DataExportJob` (max_attempts 3),
`AccountDeletionJob` (max_attempts **1**), `ConfirmDeletionJob` (stub), `ImageRetentionJob` (cron
`0 2 * * *`); Elm `Page.Settings.Consent` analytics toggle; dbt `stg_audit_log`.

**Not built (feature gaps → child issues):** writing-assistant consent (columns/worker/plug/Elm),
richer export payload + underlying tables, deeper deletion cascade + underlying tables, export/delete
Elm UI, audit-log read API + Elm page.

**Punch list (from the issue):** 16 items — ~7 in-scope test additions against v1, ~9 feature gaps.
GDPR telemetry (§12/#16) is being **instrumented in-scope** per the human's decision.

## Approach Options
- **Option A (chosen):** #121 = epic + v1 test-hardening + in-scope GDPR telemetry; de-scope the v2
  surface into seven dependency-ordered child issues (#183–#189). — Keeps #121 honest (no
  claimed-but-unbuilt story reaching green via `n/a (see #NNN)`), respects the test-issue scope-lock,
  and sequences the real feature work. Recommended and approved.
- **Option B:** build the full v2 surface in-scope — rejected: explodes a test issue into a
  multi-feature epic (new tables, a purge worker, three Elm pages, a consent-gate plug); violates the
  scope-lock; skips design passes (the #173 refresh-cascade risk).
- **Option C:** pure de-scope with no roadmap — rejected: loses the implementation sequencing.

## Phases (in-scope #121 work — against the BUILT v1 surface)

### Phase 1: Erasure invariants (SECURITY — top priority)
**Objective**: Prove right-to-erasure's audit + immutability contract has test teeth.
**Agent(s)**: testing-agent (Elixir)
**Steps**:
1. Assert `delete_account/2` writes a `user.deletion_requested` audit row (user_id = the user) BEFORE enqueue.
2. Assert `delete_user_data/1`'s Multi writes a `user.data_deleted` audit row with **`user_id: nil`**, `resource_type: "user"`, `resource_id: <deleted id>`.
3. Assert `op.event_log` is **NOT modified** during deletion (snapshot row ids/count before/after; unchanged).
**Test Command**: `just run mix test apps/core/test/stacks_web/gdpr_controller_test.exs apps/core/test/stacks/gdpr/deletion_test.exs`
**DoD Items**: Deletion audit (data_deleted); Pre-deletion audit (deletion_requested); Event log preserved (§4/§5).

### Phase 2: Job config + safety assertions
**Objective**: Lock the destructive-op safety config into tests.
**Agent(s)**: testing-agent (Elixir)
**Steps**:
1. Assert `DataExportJob` — `queue: :default`, `max_attempts: 3`.
2. Assert `AccountDeletionJob` — **`max_attempts: 1`** (no retries) and logs the failed step name on `{:error, step, …}`.
3. Assert `ImageRetentionJob` cron registration (`{"0 2 * * *", ImageRetentionJob}` in `config.exs`).
**Test Command**: `just run mix test apps/core/test/stacks/workers/`
**DoD Items**: §6 job config lines (DataExportJob, AccountDeletionJob, ImageRetentionJob cron).

### Phase 3: Image-retention storage assertions
**Objective**: Verify the storage side of the 30-day image promise, incl. failure resilience.
**Agent(s)**: testing-agent (Elixir)
**Steps**:
1. Assert `Storage.delete_image/1` is invoked per expired and per stuck image (spy/expectation on the mock backend, not just DB count).
2. Assert storage-failure resilience: `Storage.delete_image/1` returns `{:error, _}` → warning logged **and DB record still deleted** (`delete_storage_objects/1` error branch).
**Test Command**: `just run mix test apps/core/test/stacks/gdpr/image_retention_test.exs`
**DoD Items**: §7/§8 storage-call + storage-failure lines.

### Phase 4: GDPR telemetry instrumentation + firing tests
**Objective**: Add GDPR-specific telemetry (§12) with tests that fail if an emitter is removed.
**Agent(s)**: elixir-agent (Elixir — production code)
**Steps**:
1. Emit telemetry for: `DataExportJob`/`AccountDeletionJob` outcomes (incl. failed-step id), consent grant/revoke counts, image stuck/expired/orphan counts, `image.expired`-by-reason, audit-log write throughput.
2. Register the metrics in `CoreWeb.Telemetry` (Prom_Ex plugin) alongside existing metrics.
3. Firing tests following `apps/core/test/stacks/upload_telemetry_test.exs` (attach handler, exercise flow, assert the `[:stacks, :gdpr, …]` event fires with expected measurements/metadata).
**Test Command**: `just run mix test apps/core/test/stacks/` (telemetry + affected suites)
**DoD Items**: §12 GDPR telemetry (all bullets); punch #16.

### Phase 5: E2E hardening (Playwright)
**Objective**: Close the in-scope E2E gaps that don't need the (de-scoped) UI.
**Agent(s)**: testing-agent / elm-agent (Playwright)
**Steps**:
1. `/api/gdpr/export`, `/api/gdpr/account`, `/api/gdpr/consent` return **401** unauthenticated (API-level, mirrors the existing `/api/settings/*` 401 test).
2. Consent E2E hardening (analytics): assert the "Saved!" success text after save, and the "Could not save preferences. Please try again." error path on failure — beyond the current no-`.error` smoke.
**Test Command**: `e2e` Playwright (deploy-preview gate)
**DoD Items**: §1/§2 consent success+error; §2 GDPR auth guards (401 portion); punch #14 (API-401), #15.

### Phase 6: Audit-green + epic finalization (orchestrator)
**Objective**: Make the embedded Test Audit GREEN for the kept surface and finalize the epic.
**Steps**:
1. Regenerate the embedded Test Audit tables + tally: every kept-surface cell `✅` or `n/a`-with-rationale; de-scoped cells reclassified `n/a — see #18x` (pointing at the child issue), NOT left ❌/⚠️.
2. Fill the Feature-Completeness Pre-Check table: US-8.4 ✅; US-8.1/8.2/8.3/8.5 rows record "v1 backend/API built + tested here; v2 UI/feature tracked by #18x".
3. Confirm the Summary + User Stories reframe (done at scope-lock) is accurate.
**DoD Items**: Test audit GREEN; Pre-Check ✅/tracked; `just verify` passes.

### Parallel Execution
**Independent phases**: 1, 2, 3 are independent Elixir test-only phases (no shared production code) and may run in parallel worktrees. Phase 4 (telemetry) touches production code + `CoreWeb.Telemetry`; run after 1–3 to avoid churn. Phase 5 (E2E) is independent but gated behind a preview deploy; run after 4. Phase 6 is orchestrator-only, last.
**Merge order**: 1 → 2 → 3 → 4 → 5 → 6.

## Spin-out feature issues (epic children — implemented AFTER #121, in this order)
1. **#183 — GDPR data-model foundation**: migrations for `op.embeddings`, `op.blog_assistant_sessions`, `op.turn_feedback`, `op.retrieval_log`, `op.user_book_content_access` (+ confirm `op.book_content_chunks`). Root dependency; design-pass first (schema + FK/cascade decisions).
2. **#184 — Writing-assistant consent (end-to-end)**: `consent_writing_assistant[_at]` columns, controller `type` param, `ConsentCheck` 403 gate on blog chat, `WritingAssistantDataPurgeWorker` (idempotent), Elm `ToggleWritingAssistant`. Depends on #183.
3. **#185 — Deeper deletion cascade**: extend `delete_user_data/1` to the #183 tables; preserve `book_content_chunks`; assert event_log-preserved on the new surface. Depends on #183.
4. **#186 — Richer export payload**: `writing_assistant_sessions`, `writing_assistant_feedback`, `embeddings_summary` (source/title/shelf/date — no raw vectors) keys. Depends on #183.
5. **#187 — Export UI (Elm)**: `UserClicksExport → Loading → GotExportResponse (Ok/Err)` on Settings; wired to `POST /api/gdpr/export`. Independent (backend exists).
6. **#188 — Delete UI (Elm)**: `UserTypesDeleteConfirmation` (button enabled only on exact `"DELETE"`) → `UserClicksDeleteAccount → Loading → Success` + logout OutMsg. Independent.
7. **#189 — Audit-log read API + Elm page (US-8.5 read)**: paginated list endpoint + `/settings/audit-log` page. Independent.

Ordering: #183 first (root). Then #184/#185/#186 (need #183). #187/#188/#189 independent — schedule anytime.

## Open Questions
None. (Telemetry decision: instrument in-scope — resolved.)

## Integration Handoffs
- Phase 4 (telemetry) coordinates with `CoreWeb.Telemetry`/Prom_Ex; the elixir-agent must register metrics there, not only emit events.
- Phase 6 depends on all prior phases landing so the audit reflects shipped state.
- Child issues #184/#185/#186 all consume #183's schema — #183 must ship a design-pass/decision record first.
