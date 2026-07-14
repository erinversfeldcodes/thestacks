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
<!-- POST-implementation re-baseline (built + merged on feat/e2e-121). -->

Legend: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.2 — Delete All Personal Data (erasure completeness) | **Trigger wired:** `core_web/router.ex:248` `DELETE /gdpr/account` → `gdpr_controller.ex:29` `delete_account/2` enqueues `AccountDeletionJob` (`gdpr_controller.ex:39`) → `account_deletion_job.ex:6` `max_attempts: 1` (no retry on destructive op), `:16` calls `Deletion.delete_user_data/1`. **Erasure (`deletion.ex`):** single `Ecto.Multi` (`:37`); user hard-deleted `deletion.ex:68-73` → WA data model (`blog_assistant_sessions`→`turn_feedback`/`retrieval_log`, `embeddings`, `user_book_content_access`) erased via FK `ON DELETE CASCADE` (built #183 — no explicit Multi step needed); `book_content_chunks` PRESERVED (no `user_id`, no delete targets it); `:scrub_event_log` step `deletion.ex:74-110` UPDATEs PII payload/metadata to `{}` for the user-aggregate (`:101`) AND cross-aggregate free-text via `user_id`/`author_id`/`seller_id` payload keys (`:102-104`), rows never deleted (immutability); `user.data_deleted` audit row with `user_id: nil` at `deletion.ex:138-139`. | ✅ Backend-only security invariant — the "live drive" is the passing acceptance suite that reaches the erased state via the *same* `delete_user_data/1` the job calls: `deletion_test.exs` (audit row nil-actor, user-aggregate event_log scrub, cross-aggregate #185 scrub, session revocation, MFA/admin-session cascade, **schema-level FK guard**) + `gdpr_data_model_test.exs` (5 personal tables erased + corpus preserved, both direct-`Repo.delete` and real-GDPR-path). All passing. | ✅ IMPLEMENTED | — |

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

POST-implementation re-baseline (2026-07-13, `feat/e2e-121`). Single user story (US-8.2), so the 13-layer table has one happy + one sad column. Every ✅ cites a test string verified by grep of the shipped suites; every `n/a` carries a rationale. The event-flow (L4) and database (L3) layers are the erasure surface and carry the load; UI/dbt/storage/cache/cost are `n/a` with rationale (this issue adds no frontend/dbt/storage surface).

Legend: ✅ real coverage · ⚠️ shallow · ❌ missing · n/a (rationale).

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | 12 |
| ⚠️ shallow | 0 |
| ❌ missing | 0 |
| n/a (rationale) | 14 |

### 13-layer audit (US-8.2)

| # | Layer | Happy path | Sad path |
|--:|-------|------------|----------|
| 1 | API calls | ✅ `gdpr_controller_test.exs` — "returns 202 and enqueues AccountDeletionJob" | ✅ `gdpr_controller_test.exs` — "returns 401 when not authenticated" (DELETE /api/gdpr/account) |
| 2 | Auth & middleware guards | ✅ `gdpr_controller_test.exs` — "returns 202 and enqueues AccountDeletionJob" (authenticated conn required) | ✅ `gdpr_controller_test.exs` — "returns 401 when not authenticated" |
| 3 | Database interactions | ✅ `gdpr_data_model_test.exs` — "delete_user_data/1 erases the five personal tables and preserves the corpus" (WA cascade via real GDPR path) + "deleting the user row cascades to all five personal tables" (FK proof) | ✅ `deletion_test.exs` — "every op.* FK that references op.users cascades or nullifies on delete" (schema-level completeness guard) + `gdpr_data_model_test.exs` — "deleting the user preserves the shared book_content_chunks row" / "book_content_chunks is SHARED, NON-personal: it has NO user_id column" |
| 4 | Event flow & lifecycle | ✅ `deletion_test.exs` — "scrubs PII from the erased user's own event_log rows but preserves the rows" (user-aggregate) + "scrubs the user's free-text PII from events under NON-user aggregates (#185)" (cross-aggregate) + "writes a user.data_deleted audit row with nil user_id and the deleted user's id as resource_id" | ✅ `deletion_test.exs` — same two scrub tests assert unrelated rows (other aggregate / other user's `blog.post_created`) are byte-for-byte untouched; "GUC is scoped to the deletion transaction (does not leak)" proves the audit append-only trigger still blocks post-commit UPDATEs |
| 5 | Background jobs (Oban) | ✅ `account_deletion_job_test.exs` — "returns :ok and deletes user data for a valid user_id" | ✅ `account_deletion_job_test.exs` — "returns {:error, _} for a nonexistent user_id" + "logs the failed step name when the deletion Multi fails" + "is configured with max_attempts of 1 (erasure must not retry)" |
| 6 | External service calls | n/a — erasure is a pure DB transaction; no Modal/OpenLibrary/scraper calls in the delete path | n/a |
| 7 | Storage (R2 / local) | n/a — #185 erases the WA/embeddings data model in Postgres; object-storage retention is a separate concern (`cleanup_expired_uploaded_images` + `gdpr_telemetry_test.exs` image-retention tests) | n/a |
| 8 | Cache | n/a — no cache layer for the WA data model; live-session invalidation is DB-side (auth_token_families/guardian_tokens deletes, covered under L4/session-revocation in `deletion_test.exs`) | n/a |
| 9 | dbt models | n/a — deletion is operational; staging views reflect erased/scrubbed rows passively. Proto-generated `stg_*` models are covered generically; no per-erasure dbt assertion adds a guarantee | n/a |
| 10 | Elm frontend state machine | n/a — #185 is implementation-only (no new UI; delete flow pre-wired). The account-deletion trigger UI is separately covered by `frontend/tests/Page/GdprDeleteProgramTest.elm` ("success_state: a 202 response confirms the deletion was queued", "farewell_outmsg …", "error_state …") | n/a |
| 11 | Operational metrics | ✅ `gdpr_telemetry_test.exs` — "emits [:stacks, :gdpr, :deletion] with result :ok on success" (AccountDeletionJob outcome telemetry fires) | ✅ `gdpr_telemetry_test.exs` — "emits [:stacks, :gdpr, :deletion] with result :error and the failed-step id" |
| 12 | Performance & usability | n/a — covered by SLO gate (`scripts/check-slo-gate.sh`); in-test latency bounds are an anti-pattern under variable CI timing | n/a |
| 13 | Cost tracking | n/a — erasure incurs no metered external spend (no vision/LLM/scraper call in the delete path) | n/a |

### Punch list

None. 0 ❌ / 0 ⚠️. Every applicable cell has real, verified coverage; every `n/a` carries a rationale (no external/storage/cache/dbt/cost surface in the erasure path; UI is pre-wired and separately covered; L12 at the SLO gate).

### Verdict

**GREEN.** 12 ✅, 0 ⚠️, 0 ❌, 14 n/a-with-rationale across the 13-layer × US-8.2 matrix. The erasure surface (L3 database, L4 event flow, L5 Oban) is fully proven against the shipped suites `deletion_test.exs`, `gdpr_data_model_test.exs`, `account_deletion_job_test.exs`, `gdpr_controller_test.exs`, and `gdpr_telemetry_test.exs`.

## Definition of Done
- [x] `delete_user_data/1` erases `op.blog_assistant_sessions` (cascading `turn_feedback` + `retrieval_log`), `op.embeddings`, `op.user_book_content_access` — via FK `:delete_all` cascade (built in #183; proven by `gdpr_data_model_test.exs`)
- [x] `op.book_content_chunks` preserved (assertion in `gdpr_data_model_test.exs`)
- [x] `event_log` PII scrubbed during deletion — user-aggregate rows (Phase 7) + cross-aggregate free-text under `user_id`/`author_id`/`seller_id` (#185); rows preserved, payload/metadata emptied (`deletion_test.exs` "scrubs the user's free-text PII from events under NON-user aggregates")
- [x] `user.data_deleted` audit row still written (action + `user_id: nil`) — `deletion_test.exs`
- [x] Cascade is atomic (all-or-nothing) — single `Ecto.Multi`
- [x] `op.post_comments.body` (user-authored free-text) erased on deletion — the `author_id` FK is `nilify_all`, so the user delete left the comment body behind (a right-to-erasure leak). New `:erase_comments` Multi step (`deletion.ex`, before `:delete_user`) tombstones the body to `"[deleted]"` + nulls `author_id`; comments are threaded (`parent_id`), so anonymise (not delete) preserves replies — `deletion_test.exs` "tombstones the erased user's post_comment bodies but leaves other users' comments intact"
- [x] Schema-level guard TIGHTENED: every `op.*` FK referencing `op.users` (any column name) must CASCADE, OR be an allowlisted SET NULL. `SET NULL` is no longer blanket-accepted (that is what let the `post_comments.body` leak pass GREEN). Allowlist (`@nilify_user_fk_allowlist` in `deletion_test.exs`) with justifications: `transactions` (financial-audit/legal retention; no user free-text), `partners` (business entity; approver de-linked), `post_comments` (free-text body erased by `:erase_comments`; nilify preserves thread). Any other nilify user-FK or un-allowlisted table FAILS the guard — a future bare-nilify personal table is caught. `deletion_test.exs` "every op.* FK that references op.users cascades, or nullifies only on the allowlist"
- [x] Feature-Completeness Pre-Check (above) is ✅ for US-8.2 — the erasure happy path is built end-to-end (router → controller → `AccountDeletionJob` → `delete_user_data/1` WA cascade + event_log scrub + audit row) and proven live via the passing `deletion_test.exs` + `gdpr_data_model_test.exs` acceptance suites; no named story reaches GREEN via `n/a (see #NNN)`.
- [x] Test audit (embedded above) is GREEN — every cell ✅ or n/a-with-rationale; 0 ❌, 0 ⚠️; regenerate as the final step.
- [ ] `just verify` passes

## Dependencies
#183 (data-model foundation — the tables this cascade deletes).

## Agent Assignment
elixir-agent.

## Progress Notes

- 2026-07-14 (elixir-agent, PE-gate P1 + P2#4): Closed a right-to-erasure leak the schema guard was blind to. `op.post_comments.body` is user-authored free-text PII; its `author_id` FK is `nilify_all`, so `delete_user_data/1` nulled authorship but left the comment body intact. Added an `:erase_comments` Multi step (before `:delete_user`, keeps the txn atomic) that tombstones the erased user's comment bodies to `"[deleted]"` and nulls `author_id`. Comments are threaded (`parent_id` → replies; `Blog.list_comments/2` builds top-level + replies-by-parent), so anonymise — not hard-delete — preserves thread structure. Test-first: proved the body survived before the fix. Tightened the schema-guard test to stop treating `SET NULL` as always-safe (it was what let this leak stay GREEN): CASCADE always passes; SET NULL passes only for an explicit allowlist (`transactions`, `partners`, `post_comments`) each with a documented justification — any other nilify user-FK now fails. Swept all `op.*` free-text columns with a user FK: the only nilify user-FK free-text table was `post_comments`; all other free-text (blog_posts, reading_groups, marketplace listings/messages, blog_assistant_sessions, embeddings) is CASCADE-erased with the user. No remaining user free-text/PII the erasure misses.
