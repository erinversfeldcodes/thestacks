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
<!-- Post-implementation re-baseline: 2026-07-13 (branch feat/e2e-121, #183 merged). -->

#183 names **no user stories** — it is foundational data-model work (root dependency for
#184/#185/#186). Per the skill, story-less work is still traced end-to-end: the deliverable is
that the 6 tables *exist* with the correct ownership, FK `:delete_all` cascades, pgvector column,
and personal-vs-shared classification, and that the erasure/preservation invariant #185 leans on
holds. There is no user-facing surface of its own (wired later by #184/#185/#186/#188), so a live
app-drive is **N/A** — the validation is the passing data-model test suite that exercises the real
`Repo`/`Stacks.GDPR.Deletion` path against a live Postgres.

| Deliverable (in place of a user story) | Built-evidence (file:line) | Live-drive result | Verdict |
|----------------------------------------|-----------------------------|-------------------|---------|
| Design pass FIRST (ADR) | `docs/decisions/017-gdpr-writing-assistant-data-model.md` (schema, FK/cascade dirs §2, personal-vs-shared §3, event-payload contract §4, pgvector escape-hatch §5) | N/A (no runtime surface) | ✅ built |
| `op.blog_assistant_sessions` — PERSONAL, `user_id` FK `:delete_all` | migration `20260713181718_create_blog_assistant_sessions.exs:23`; schema `lib/stacks/gen/writing_assistant/session.ex:14` | Cascade proven by `gdpr_data_model_test.exs:146` | ✅ built |
| `op.turn_feedback` — PERSONAL, `session_id` FK `:delete_all` (transitive) | migration `20260713181719_create_turn_feedback.exs:24-28`; schema `gen/writing_assistant/turn_feedback.ex` | `gdpr_data_model_test.exs:146` | ✅ built |
| `op.retrieval_log` — PERSONAL, `session_id` FK `:delete_all` (transitive) | migration `20260713181720_create_retrieval_log.exs:24-28`; schema `gen/writing_assistant/retrieval_log.ex` | `gdpr_data_model_test.exs:146` | ✅ built |
| `op.user_book_content_access` — PERSONAL, `user_id` + `book_id` FK `:delete_all` | migration `20260713181721_create_user_book_content_access.exs:23,26` | `gdpr_data_model_test.exs:146` | ✅ built |
| `op.embeddings` — PERSONAL, `user_id` FK `:delete_all` + `vector(1024)` + HNSW | migration `20260713181722_...:37-59`; hand-written schema `lib/stacks/writing_assistant/embedding.ex:23-33` (`Pgvector.Ecto.Vector`) | Vector round-trip `gdpr_data_model_test.exs:130`; cascade `:146` | ✅ built |
| `op.book_content_chunks` — SHARED, NON-personal, **no `user_id`** (PRESERVED) + `vector(1024)` | migration `20260713181722_...:64-85`; schema `lib/stacks/writing_assistant/book_content_chunk.ex:24-32` | Preserved on user delete `gdpr_data_model_test.exs:160` and via real GDPR path `:172` | ✅ built |

Verdict: **✅ IMPLEMENTED** — all 6 tables built end-to-end with correct FK cascades, pgvector
column, and the shared-corpus preservation invariant, matching ADR 017. Design-pass-first was
honoured (ADR landed before migrations). No named user story ⇒ nothing de-scoped, no `n/a (see #NNN)`
reclassification of any happy path. Live app-drive N/A (no user-facing surface); the erasure/
preservation invariant is validated live-against-Postgres by `gdpr_data_model_test.exs`.

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

Re-baseline (post-implementation): 2026-07-13, branch `feat/e2e-121`, #183 merged.
Read/grep-based — the epic `just verify` already ran; test names below were grep-confirmed
against `apps/core/test/**` + `dbt/models/staging/schema.yml`.

Legend: ✅ real coverage · ⚠️ shallow · ❌ missing · n/a (one-line rationale).

#183 is a **data-model foundation with no user stories** and no surface of its own (API/UI/events/
jobs are wired later by #184/#185/#186/#188). The 13 layers are therefore assessed against a single
concern — "the data model exists with correct cascades + pgvector + preservation invariant." Most
user-facing layers are genuinely `n/a`; the load-bearing cells are **L3 (DB)** and the erasure/
preservation invariants, plus **L9 (dbt)** for the four codegen-clean staging models.

### Framework-layer summary

| Layer | Data-Model Foundation |
|-------|-----------------------|
| Elixir (DB / cascade / pgvector) | ✅ |
| dbt (staging models) | ✅ |
| Elm / Python / Rust / E2E | n/a |

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | 3 (L3 happy, L3 sad, L9) |
| ⚠️ shallow | 0 |
| ❌ missing | 0 |
| n/a (not applicable / covered higher up / by-design) | 10 |

### Full audit table (13 layers × the single data-model concern)

| # | Layer | Happy path | Sad / invariant path | Verdict |
|--:|-------|------------|----------------------|---------|
| 1 | API calls | n/a — no endpoints of its own; wired by #184/#185/#186 (impl-only issue, see Wiring). | n/a | n/a |
| 2 | Auth & middleware guards | n/a — no routes; no guard surface until #184 wires the writing-assistant. | n/a | n/a |
| 3 | Database interactions | ✅ `gdpr_data_model_test.exs:82` "the five personal tables + shared corpus table exist with expected columns"; `:120` "the vector extension is installed"; `:125` "embedding columns are vector(1024) on both embeddings and book_content_chunks"; `:130` "a 1024-dim vector round-trips through the Pgvector.Ecto.Vector field"; `:146` "deleting the user row cascades to all five personal tables". | ✅ `gdpr_data_model_test.exs:114` "book_content_chunks is SHARED, NON-personal: it has NO user_id column"; `:160` "deleting the user preserves the shared book_content_chunks row"; `:172` "delete_user_data/1 erases the five personal tables and preserves the corpus"; schema-level guard `deletion_test.exs:303` "every op.* FK that references op.users cascades or nullifies on delete". | ✅ |
| 4 | Event flow & lifecycle | n/a — this model emits **no events of its own**. ADR 017 §4 fixes the going-forward contract (UUID-only payloads); the guardrail test belongs to the first issue that emits `blog_assistant.*`/`embedding.*` (none yet). | n/a — legacy-row payload scrub is `deletion_test.exs:126` (covered by #185, not this table set). | n/a |
| 5 | Background jobs (Oban) | n/a — no jobs; no async pipeline in this foundation. | n/a | n/a |
| 6 | External service calls | n/a — no external calls. The embedding-model integration (Together AI bge-m3) is future work; only the `vector(1024)` column shape lands here. | n/a | n/a |
| 7 | Storage (R2 / local) | n/a — no blob/object storage; vectors live in-row in Postgres. | n/a | n/a |
| 8 | Cache | n/a — no cache layer for these tables. | n/a | n/a |
| 9 | dbt models | ✅ four codegen-clean staging models exist with real tests — `dbt/models/staging/schema.yml` `stg_blog_assistant_sessions` (`id` not_null+unique, `user_id`/`status` not_null), `stg_retrieval_log`, `stg_turn_feedback` (`rating` accepted_values `['up','down']`), `stg_user_book_content_access`. | ✅ same schema.yml — `retrieval_log.query` is **dbt-excluded** (absent from `stg_retrieval_log` columns) per ADR 017 §5 so user free-text/PII never reaches the warehouse; `embeddings`/`book_content_chunks` are `skip_dbt` (pure retrieval infra). | ✅ |
| 10 | Elm frontend state machine | n/a — no UI; the writing-assistant surface is built/ wired by #184 and #188. | n/a | n/a |
| 11 | Operational metrics | n/a — covered by SLO gate (`scripts/check-slo-gate.sh`); no per-table SLI for a schema-only change. | n/a | n/a |
| 12 | Performance & usability | n/a — covered by SLO gate; HNSW ANN index built on an empty table (migration `20260713181722_...:58-60,83-85`). | n/a | n/a |
| 13 | Cost tracking | n/a — no cost-incurring calls in this foundation (embedding generation cost is tracked by the future issue that calls the model). | n/a | n/a |

### Punch list

None. 0 ❌ / 0 ⚠️. Every applicable cell (L3 happy, L3 sad/invariant, L9) is ✅ with a
grep-confirmed test; the remaining 10 layers are `n/a` with an inline rationale (no surface of
their own, covered by the SLO gate, or by-design — event contract deferred to first emitter).

### Verdict

**GREEN (re-baseline).** The data-model foundation is fully covered at the only layers that apply
to it: DB cascade/pgvector/preservation (`gdpr_data_model_test.exs`, 8 tests + `deletion_test.exs`
schema-level FK guard) and dbt staging (`schema.yml` not_null/unique/accepted_values, query text
excluded). No named story ⇒ no feature-completeness gap folded in as `n/a`. Residual risk carried
forward, not a gap here: the ADR §4 UUID-only event-payload guardrail must be enforced by the first
issue that emits a `blog_assistant.*`/`embedding.*` event.

## Definition of Done
- [ ] `docs/decisions/` record landed (schema, FK/cascade, ownership, personal-vs-shared classification)
- [ ] Migrations for `op.embeddings`, `op.blog_assistant_sessions`, `op.turn_feedback`, `op.retrieval_log`, `op.user_book_content_access`
- [ ] `op.turn_feedback` and `op.retrieval_log` FK-cascade from `op.blog_assistant_sessions`
- [ ] `op.book_content_chunks` confirmed/annotated as shared, NON-personal (preserved by erasure)
- [ ] Proto manifest (`proto/persisted.exs`) updated and `mix proto.sync` run if these are `op.*` tables (no drift under `--check`)
- [ ] `just verify` passes
- [x] Feature-Completeness Pre-Check (above) is ✅ — the data-model deliverables are built end-to-end (6 tables, FK `:delete_all` cascades, `vector(1024)`, shared-corpus preservation) and validated live-against-Postgres by `gdpr_data_model_test.exs`; no named story ⇒ nothing de-scoped and no happy path reaches GREEN via `n/a (see #NNN)`. Live app-drive N/A (no user-facing surface).
- [x] Test audit (embedded above) is GREEN — every cell ✅ or n/a-with-rationale; 0 ❌, 0 ⚠️; regenerate as the final step.

## Dependencies
None — this is the root dependency for #184, #185, #186.

## Agent Assignment
database-agent (or elixir-agent).

## Progress Notes
