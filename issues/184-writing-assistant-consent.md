# Issue #184: Writing-Assistant Consent (end-to-end)

**Epic:** #121 (E2E Test Suite — GDPR Compliance)

## Summary
Build the full consent surface for AI writing-assistant personalisation — schema columns, controller handling, a consent gate on blog chat, a purge worker on revocation, and the Elm toggle — end to end.

## User Stories
US-8.3 (Consent Management — writing-assistant half).

## Goal
A user can grant or revoke consent for writing-assistant personalisation; granting records a timestamp and unlocks blog chat, revoking enqueues a purge of their AI data and re-gates blog chat (403).

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Does this issue touch more than 3 controllers? No (GDPRController + the blog chat gate via a plug).
- Does this issue add more than 2 new endpoints? No (reuses `POST /api/gdpr/consent`).
- Does this issue exceed ~300 lines of production code? Borderline — watch worker + Elm; split if needed.
- Does this issue combine unrelated concerns? No (all writing-assistant consent).

## Wiring
<!-- Every issue must declare whether it includes router/UI wiring. -->
- [x] This issue includes router wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
<!-- Baseline = "to verify"; fill verdicts + file:line evidence when picked up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.3 — Consent Management (writing-assistant) | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- Add `consent_writing_assistant` + `consent_writing_assistant_at` columns to `op.users` (proto-generated — add fields to the proto → `mix proto.sync`).
- `GDPRController.update_consent/2` honours `type: "writing_assistant"`: 200 + `consent_writing_assistant: true` and `consent_writing_assistant_at` timestamp on grant; on revoke (200) enqueue the purge worker.
- `Stacks.Plugs.ConsentCheck` gates blog chat: `POST /api/blog/posts/:id/chat` → 403 when `consent_writing_assistant` is false.
- `WritingAssistantDataPurgeWorker` — deletes the user's AI data: `op.blog_assistant_sessions`, `op.turn_feedback`, `op.retrieval_log`, user-scoped `op.embeddings`, `op.user_book_content_access`. Idempotent / safe to retry. PRESERVES `op.book_content_chunks`.
- Elm `Page.Settings.Consent`: `ToggleWritingAssistant` Msg + save wiring, including the off-toggle description string from #121 §1: "Your shelf and writing history are used to personalise writing suggestions. Disabling this turns off the writing assistant and deletes your session history and embeddings."

## Reviewer Context
<!-- Non-obvious project conventions relevant to this issue. -->
- Consent emits no events by design — state is the timestamp on the user row.
- The purge worker must be idempotent (safe to retry); it must never touch `book_content_chunks` (shared, non-personal).
- `op.users` is proto-generated — add consent columns via the proto, not the schema file.

## Test Audit
Test Audit: generated when picked up.

## Definition of Done
- [ ] `consent_writing_assistant` + `consent_writing_assistant_at` columns on `op.users` (via proto)
- [ ] `GDPRController.update_consent/2` handles `type: "writing_assistant"` (grant 200 + timestamp; revoke enqueues purge worker)
- [ ] `Stacks.Plugs.ConsentCheck` returns 403 on `POST /api/blog/posts/:id/chat` when consent is false
- [ ] `WritingAssistantDataPurgeWorker` deletes all user AI data, idempotent, preserves `book_content_chunks`
- [ ] Elm `ToggleWritingAssistant` Msg + save + off-toggle description string
- [ ] `just verify` passes
- [ ] E2E / elm-test coverage

## Dependencies
#183 (data-model foundation — the tables the purge worker deletes).

## Agent Assignment
elixir-agent + elm-agent.

## Progress Notes
