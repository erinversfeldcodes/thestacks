# Issue #186: GDPR Richer Export Payload

**Epic:** #121 (E2E Test Suite — GDPR Compliance)

## Summary
Complete the GDPR data-export payload from the current 4 keys to all 8, adding the writing-assistant and embeddings-summary data (no raw vectors).

## User Stories
US-8.1 (Export Personal Data — data-portability completeness).

## Goal
`export_user_data/2` returns a payload with all 8 keys, giving the user a complete, portable copy of their personal data including writing-assistant history and an embeddings summary.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Does this issue touch more than 3 controllers? No (Export module only).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No.
- Does this issue combine unrelated concerns? No (export payload only).

## Wiring
<!-- Every issue must declare whether it includes router/UI wiring. -->
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Export flow already wired (GDPRController + DataExportJob).

## Feature-Completeness Pre-Check
<!-- Re-baselined 2026-07-13 (BUILT + merged on feat/e2e-121). Read/grep trace. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.1 — Export Personal Data (completeness) | Route `POST /api/gdpr/export` wired under `[:api, :authenticated]` — `router.ex:247` (scope opens `router.ex:176`) → `GDPRController.export/2` enqueues `DataExportJob` for `current_resource`, returns 202 — `gdpr_controller.ex:15-26` → `DataExportJob.perform/1` calls `Export.export_user_data/1` — `data_export_job.ex:13-28` → `Export.export_user_data/2` returns all **8 keys** `exported_at, user, bookshelves, placements, placement_history, writing_assistant_sessions, writing_assistant_feedback, embeddings_summary` — `export.ex:65-84`; sessions user-scoped `export.ex:40-43`, feedback scoped via inner-join on session.user_id `export.ex:45-49`, `embeddings_summary` **select-only, raw `embedding` vector deliberately NOT selected** `export.ex:54-63` | Backend-only surface: passing `apps/core/test/stacks/gdpr_test.exs` (8-key set assertion, per-user scoping incl. no-leak of another user's sessions/feedback, embeddings_summary metadata-only + no raw vector in JSON) proves the payload live. End-to-end user-facing drive is the export UI (#187), which triggers this job. | ✅ | Built in-scope. |

Verdict: ✅ implemented (payload built end-to-end; select-only embeddings summary with no raw vector; user-scoped) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- `Stacks.GDPR.Export.export_user_data/2` adds keys:
  - `writing_assistant_sessions`,
  - `writing_assistant_feedback`,
  - `embeddings_summary` — source type, title, shelf, date only; **NO raw vectors**.
- Final payload keys = `exported_at`, `user`, `bookshelves`, `placements`, `placement_history`, `writing_assistant_sessions`, `writing_assistant_feedback`, `embeddings_summary` (8 keys).

## Reviewer Context
<!-- Non-obvious project conventions relevant to this issue. -->
- The embeddings summary must never include raw vectors — only source type / title / shelf / date. Exporting vectors is a data-leak risk and adds no portability value.

## Test Audit

Re-baseline: 2026-07-13 (post-implementation, BUILT + merged on `feat/e2e-121`). Every ✅ verified by Read/grep of the shipped suites. Single user story (US-8.1); the surface is the backend export payload.

Legend: ✅ real coverage · ⚠️ shallow · ❌ missing · n/a not applicable (one-line rationale).

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | 9 |
| ⚠️ shallow | 0 |
| ❌ missing | 0 |
| n/a (rationale inline) | 8 layers |

### 13-layer audit — US-8.1 (export payload)

| # | Layer | Happy | Sad |
|---|-------|-------|-----|
| 1 | API calls | ✅ `stacks_web/gdpr_controller_test.exs` — "returns 202 and enqueues DataExportJob" | n/a — `POST /api/gdpr/export` takes no body/params; the only failure mode (unknown/absent user) is covered at the auth (L2) and job/module (L3/L5) layers. |
| 2 | Auth & middleware guards | ✅ `stacks_web/gdpr_controller_test.exs` — "returns 202 and enqueues DataExportJob" (authenticated `current_resource` drives the job) | ✅ `stacks_web/gdpr_controller_test.exs` — "returns 401 when not authenticated" |
| 3 | Database interactions | ✅ `stacks/gdpr_test.exs` — "includes bookshelves and placements", "includes only the user's writing-assistant sessions and feedback" (cross-user isolation), "embeddings_summary lists metadata but NEVER the raw vector", "embeddings_summary and writing-assistant keys default to empty lists" | ✅ `stacks/gdpr_test.exs` — "returns error for unknown user" |
| 4 | Event flow & lifecycle | n/a — data export is a read-only portability read; it emits no `event_log` event by design (outcome is surfaced via telemetry, L11). | n/a — same. |
| 5 | Background jobs (Oban) | ✅ `stacks/workers/data_export_job_test.exs` — "returns :ok for a valid user_id" + config: "runs on the :default queue", "is configured with max_attempts of 3" | ✅ `stacks/workers/data_export_job_test.exs` — "returns {:error, _} for a nonexistent user_id" |
| 6 | External service calls | n/a — export reads only local `op.*` tables; no external/upstream calls. | n/a |
| 7 | Storage (R2 / local) | n/a — export delivery/persistence is stubbed (`data_export_job.ex:17-19` logs; production write is future/#187). This issue's charter is payload completeness (the 8 keys), not delivery. | n/a |
| 8 | Cache interactions | n/a — export reads a fresh snapshot straight from the DB by design; no cache layer. | n/a |
| 9 | dbt model dependencies | n/a — export reads operational `op.*` tables directly, not dbt marts. | n/a |
| 10 | Elm frontend state machine | n/a — backend-only issue (Wiring = implementation only); the user-facing export UI is #187 and carries its own frontend audit. | n/a |
| 11 | Operational metrics | ✅ `stacks/gdpr_telemetry_test.exs` — "emits [:stacks, :gdpr, :export] with result :ok on success" | ✅ `stacks/gdpr_telemetry_test.exs` — "emits [:stacks, :gdpr, :export] with result :error on failure" |
| 12 | Performance & usability | n/a — covered by SLO gate (`scripts/check-slo-gate.sh`), not per-US unit tests. | n/a |
| 13 | Cost tracking | n/a — DB-read only; no metered external/LLM spend to record. | n/a |

### Punch list

None. 0 ❌, 0 ⚠️. Every applicable cell has real coverage; every n/a carries a rationale (read-only-by-design, backend-only, delivery-out-of-scope, or covered at the SLO gate).

## Definition of Done
- [x] `export_user_data/2` adds `writing_assistant_sessions` key — `gdpr_test.exs` "includes only the user's writing-assistant sessions and feedback"
- [x] `export_user_data/2` adds `writing_assistant_feedback` key — same
- [x] `export_user_data/2` adds `embeddings_summary` key (metadata, no raw vectors) — `gdpr_test.exs` "embeddings_summary lists metadata but NEVER the raw vector"
- [x] Final payload = all 8 keys — `gdpr_test.exs` 8-key set assertion
- [x] `just verify` passes
- [x] Feature-Completeness Pre-Check (above) is ✅ for every named user story — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is either built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [x] Test audit (embedded above) is GREEN — every cell ✅ or n/a-with-rationale; 0 ❌, 0 ⚠️; regenerate as the final step.
- [x] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — 8-key export payload, raw vectors deliberately excluded, asserted.

## Dependencies
#183 (data-model foundation — the tables this payload reads).

## Agent Assignment
elixir-agent.

## Progress Notes
