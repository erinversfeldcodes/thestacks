# Issue #183: GDPR Data-Model Foundation (writing-assistant / embeddings tables)

**Epic:** #121 (E2E Test Suite — GDPR Compliance)

## Summary
Create the operational tables that the richer export (#186), deeper deletion cascade (#185), and writing-assistant consent (#184) all depend on. This is the ROOT dependency for the de-scoped v2 GDPR surface — nothing downstream can be built until these tables exist.

## User Stories
None — foundational data-model work supporting US-8.1, US-8.2, US-8.3. (Even story-less work must be validatable — see Definition of Done.)

## Goal
The operational tables backing the writing-assistant / embeddings feature exist, with correct ownership, FK/cascade behaviour, and a clear personal-vs-shared classification, so that erasure, export, and consent can be built on top of them.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Does this issue touch more than 3 controllers? No (migrations only).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? Borderline — migrations + schemas; split by table if it grows.
- Does this issue combine unrelated concerns? No (all one data-model foundation).

## Wiring
<!-- Every issue must declare whether it includes router/UI wiring. -->
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issues #184, #185, #186.

## Feature-Completeness Pre-Check
<!-- Baseline = "to verify"; fill verdicts + file:line evidence when picked up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| n/a — no user stories (foundational data-model) | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- **Design pass FIRST:** land a `docs/decisions/` record (schema, FK/cascade direction, ownership, personal-vs-shared classification) before writing migrations. This is a non-trivial data model — do not skip.
- Migrations for the following operational tables:
  - `op.embeddings` — user-scoped vectors (source type, title, shelf, date + vector).
  - `op.blog_assistant_sessions` — writing-assistant session records (user-scoped).
  - `op.turn_feedback` — FK cascade from `op.blog_assistant_sessions`.
  - `op.retrieval_log` — FK cascade from `op.blog_assistant_sessions`.
  - `op.user_book_content_access` — user-scoped access records.
- Confirm / annotate `op.book_content_chunks` as **shared, NON-personal** — must be PRESERVED by erasure (#185 preserves it; classify it so that invariant is unambiguous).
- If these become `op.*` tables they are **proto-generated** per `mix proto.sync` — check `proto/persisted.exs` (the message → table manifest) and the CLAUDE.md proto codegen rules. Ecto schemas land in `apps/core/lib/stacks/gen/`; do not hand-edit generated files. Adding a column = add the field to the proto → `mix proto.sync`.

## Reviewer Context
<!-- Non-obvious project conventions relevant to this issue. -->
- All `op.*` tables use UUID PKs + TIMESTAMPTZ (project convention).
- `op.*` tables are proto-generated — `mix proto.sync --check` runs in CI; drift fails the build. Add fields via the proto, not the schema file.
- `book_content_chunks` holds no personal data (shared corpus) — its preservation under erasure is load-bearing for #185.

### ⚠️ Revisit on this issue — event_log "nothing to scrub" assumption
GDPR erasure currently leaves `op.event_log` **untouched** because event payloads carry only UUIDs
(no PII) — asserted by #121 Phase 1 (`deletion_test.exs` full-row immutability test) and now stated in
`Stacks.Events`' moduledoc (corrected 2026-07-13, replacing a stale "erasure zeroes out payloads" line
that described unbuilt behavior). **If the writing-assistant / embeddings data model (this issue) ever
emits events whose payloads contain richer, PII-adjacent content**, that assumption breaks and erasure
must scrub or the payload contract must stay UUID-only. Decide this here: either (a) keep new events'
payloads strictly UUID-only, or (b) add payload-scrubbing to `Stacks.GDPR.Deletion` and update the
`Events` moduledoc + the #121 immutability test accordingly.

## Test Audit
Test Audit: generated when picked up.

## Definition of Done
- [ ] `docs/decisions/` record landed (schema, FK/cascade, ownership, personal-vs-shared classification)
- [ ] Migrations for `op.embeddings`, `op.blog_assistant_sessions`, `op.turn_feedback`, `op.retrieval_log`, `op.user_book_content_access`
- [ ] `op.turn_feedback` and `op.retrieval_log` FK-cascade from `op.blog_assistant_sessions`
- [ ] `op.book_content_chunks` confirmed/annotated as shared, NON-personal (preserved by erasure)
- [ ] Proto manifest (`proto/persisted.exs`) updated and `mix proto.sync` run if these are `op.*` tables (no drift under `--check`)
- [ ] `just verify` passes

## Dependencies
None — this is the root dependency for #184, #185, #186.

## Agent Assignment
database-agent (or elixir-agent).

## Progress Notes
