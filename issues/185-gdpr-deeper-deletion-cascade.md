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
- **event_log scrub (reconciled with #121 Phase 7):** the WA cascade above already works via FK `:delete_all` (built in #183; proven by `gdpr_data_model_test.exs`), so no explicit Multi delete steps for those tables are needed. For `event_log`, "untouched" is NO LONGER accurate: Phase 7 scrubs the user's own `aggregate_type == "user"` rows, and #185 EXTENDS the `:scrub_event_log` step to also scrub the user's **free-text PII under non-`user` aggregates** — notably `blog.post_created` / `blog.post_published` which carry the user's post `title` + `user_id` (matched by payload `user_id`/`author_id`/`seller_id`). Rows are UPDATEd to empty payload/metadata (immutability), never deleted. Remaining bare-UUID references are acceptable per the UUIDs-are-not-PII contract.
- Assert the `user.data_deleted` audit row is still written (action + `user_id: nil`).

## Reviewer Context
<!-- Non-obvious project conventions relevant to this issue. -->
- Destructive/atomic — extend the existing `Ecto.Multi`; keep it all-or-nothing (all steps succeed or all roll back).
- `AccountDeletionJob` has `max_attempts: 1` — no retries on a destructive op; failures require manual intervention.
- `event_log` rows are never DELETED (immutability); the erased user's PII-bearing payload/metadata is scrubbed in place (Phase 7 for `user` aggregate + #185 for cross-aggregate free-text). Do not delete event rows.

## Test Audit
Test Audit: generated when picked up.

## Definition of Done
- [x] `delete_user_data/1` erases `op.blog_assistant_sessions` (cascading `turn_feedback` + `retrieval_log`), `op.embeddings`, `op.user_book_content_access` — via FK `:delete_all` cascade (built in #183; proven by `gdpr_data_model_test.exs`)
- [x] `op.book_content_chunks` preserved (assertion in `gdpr_data_model_test.exs`)
- [x] `event_log` PII scrubbed during deletion — user-aggregate rows (Phase 7) + cross-aggregate free-text under `user_id`/`author_id`/`seller_id` (#185); rows preserved, payload/metadata emptied (`deletion_test.exs` "scrubs the user's free-text PII from events under NON-user aggregates")
- [x] `user.data_deleted` audit row still written (action + `user_id: nil`) — `deletion_test.exs`
- [x] Cascade is atomic (all-or-nothing) — single `Ecto.Multi`
- [x] Schema-level guard: every `op.*` FK referencing `op.users` (any column name — user_id/author_id/seller_id/owner_id/…) cascades or nullifies on delete — `deletion_test.exs` "erasure completeness — schema-level guard"
- [ ] `just verify` passes

## Dependencies
#183 (data-model foundation — the tables this cascade deletes).

## Agent Assignment
elixir-agent.

## Progress Notes
