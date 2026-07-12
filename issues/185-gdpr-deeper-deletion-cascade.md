# Issue #185: GDPR Deeper Deletion Cascade

**Epic:** #121 (E2E Test Suite — GDPR Compliance)

## Summary
Extend right-to-erasure to the writing-assistant / embeddings data model so that deleting a user removes all of their AI-derived personal data atomically.

## User Stories
US-8.2 (Delete All Personal Data — erasure completeness — **SECURITY**).

## Goal
`delete_user_data/1` fully erases the user's writing-assistant, embeddings, and content-access data in a single all-or-nothing transaction, while preserving shared non-personal data and leaving the immutable `event_log` untouched.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Does this issue touch more than 3 controllers? No (context module only).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No (extends an existing Multi).
- Does this issue combine unrelated concerns? No (erasure cascade only).

## Wiring
<!-- Every issue must declare whether it includes router/UI wiring. -->
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Delete flow already wired (GDPRController + AccountDeletionJob).

## Feature-Completeness Pre-Check
<!-- Baseline = "to verify"; fill verdicts + file:line evidence when picked up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.2 — Delete All Personal Data (erasure completeness) | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- Extend the `Stacks.GDPR.Deletion.delete_user_data/1` `Ecto.Multi` to delete, in a safe FK-respecting order:
  - `op.blog_assistant_sessions` (cascades `op.turn_feedback` + `op.retrieval_log`),
  - user-scoped `op.embeddings`,
  - `op.user_book_content_access`.
- PRESERVE `op.book_content_chunks` — shared corpus, no personal data.
- Keep `event_log` untouched (UUID-only invariant — nothing to scrub).
- Assert the `user.data_deleted` audit row is still written (action + `user_id: nil`).

## Reviewer Context
<!-- Non-obvious project conventions relevant to this issue. -->
- Destructive/atomic — extend the existing `Ecto.Multi`; keep it all-or-nothing (all steps succeed or all roll back).
- `AccountDeletionJob` has `max_attempts: 1` — no retries on a destructive op; failures require manual intervention.
- Event payloads are UUID-only, so `event_log` is not scrubbed during deletion — do not add event deletion.

## Test Audit
Test Audit: generated when picked up.

## Definition of Done
- [ ] `delete_user_data/1` Multi deletes `op.blog_assistant_sessions` (cascading `turn_feedback` + `retrieval_log`)
- [ ] `delete_user_data/1` deletes user-scoped `op.embeddings` and `op.user_book_content_access`
- [ ] `op.book_content_chunks` preserved (assertion)
- [ ] `event_log` untouched during deletion (assertion)
- [ ] `user.data_deleted` audit row still written (action + `user_id: nil`)
- [ ] Cascade is atomic (all-or-nothing)
- [ ] `just verify` passes

## Dependencies
#183 (data-model foundation — the tables this cascade deletes).

## Agent Assignment
elixir-agent.

## Progress Notes
