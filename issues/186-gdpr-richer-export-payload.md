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
<!-- Baseline = "to verify"; fill verdicts + file:line evidence when picked up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.1 — Export Personal Data (completeness) | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

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
Test Audit: generated when picked up.

## Definition of Done
- [ ] `export_user_data/2` adds `writing_assistant_sessions` key
- [ ] `export_user_data/2` adds `writing_assistant_feedback` key
- [ ] `export_user_data/2` adds `embeddings_summary` key (source type/title/shelf/date, no raw vectors)
- [ ] Final payload = all 8 keys
- [ ] `just verify` passes

## Dependencies
#183 (data-model foundation — the tables this payload reads).

## Agent Assignment
elixir-agent.

## Progress Notes
