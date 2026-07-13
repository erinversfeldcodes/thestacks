# ADR 017: GDPR Data Model for the Writing-Assistant / Embeddings Surface

**Status:** Proposed (design pass for Issue #183 — no migrations written yet)
**Date:** 2026-07-13
**Deciders:** The Stacks Orchestrator, database-agent
**Technical area:** Data model, GDPR (erasure/export), proto codegen, pgvector
**Epic:** #121 (E2E GDPR compliance) · **Issue:** #183 (root dependency for #184/#185/#186)

---

## Context

Issue #183 is the ROOT data-model dependency for the de-scoped v2 GDPR surface:
richer export (#186), deeper deletion cascade (#185), and writing-assistant
consent (#184). Nothing downstream can be built until these operational tables
exist with correct ownership, FK/cascade behaviour, and an unambiguous
personal-vs-shared classification. The issue mandates a `docs/decisions/` record
**before** any migration — this ADR is that record.

Five new `op.*` tables plus one shared corpus table are in scope. All `op.*`
tables in this repo are proto-generated (ADR 007, ADR 009): a message in
`proto/persisted.exs` drives `mix proto.sync`, which generates the Ecto schema
(`apps/core/lib/stacks/gen/`), the CREATE TABLE migration, the dbt staging model,
and `schema.yml`. `mix proto.sync --check` runs in CI; drift fails the build.

### Grounding (verified against the repo, not assumed)

- **Manifest supports FK cascade.** `MigrationGenerator.column_line/3`
  (`apps/core/lib/mix/tasks/proto_sync/migration_generator.ex:150-165`) emits
  `references(:<table>, type: :binary_id, prefix: "op", on_delete: :<x>)` when a
  `field_override` carries `references_table:` + `on_delete:`. FK columns get an
  auto-created index (`index_block/1`, same file). Precedent: `op.post_comments`
  in `proto/persisted.exs` uses `references_table:` + `on_delete: :delete_all`
  (post_id) and `:nilify_all` (author_id).
- **Erasure relies on FK `:delete_all`.** `Stacks.GDPR.Deletion.delete_user_data/1`
  (`apps/core/lib/stacks/gdpr/deletion.ex`) runs an `Ecto.Multi` that ends with
  `repo.delete(user)`. Any table whose `user_id` FK is `on_delete: :delete_all`
  is cascade-deleted by that single row delete — no per-table Multi step needed.
  (The module only adds explicit steps for tables that have **no** cascading FK:
  bookshelves/placements/history and the schemaless `guardian_tokens`/
  `auth_token_families`.) This confirms the #121 Phase 7 finding that built user
  tables rely on FK `:delete_all` for erasure reach.
- **Event scrub already exists.** `deletion.ex` has a `:scrub_event_log` step that
  UPDATEs the erased user's `op.event_log` rows to `payload: %{}, metadata: %{}`;
  `Stacks.Events` moduledoc states the going-forward `user.*` contract is
  UUID-only payloads (corrected 2026-07-13). The scrub is a defence-in-depth
  safety net for legacy rows.
- **No pgvector anywhere.** `grep -rniE "pgvector|vector"` over `nix/`,
  `flake.nix`, `deploy/`, and `structure.sql` returns nothing. The only
  vector-adjacent precedent is a raw-SQL `execute` migration adding a `tsvector`
  GENERATED column (`20260307000001_add_books_tsvector_column.exs`). There is no
  `CREATE EXTENSION` in any migration.
- **The proto→migration type table has no vector type.** ADR 009's mapping is
  `string→text, int32→integer, int64→bigint, float/double→double precision,
  bool→boolean, bytes→bytea, Timestamp→timestamptz, map→jsonb, enum→text`.
  `MigrationGenerator.format_migration_type/1` **raises** ("Unsupported migration
  type") on any type outside that set. There is no raw-column / custom-SQL-type
  escape hatch in the generator.
- **`op.book_content_chunks` does not exist yet.** It is referenced only by the
  issue text; it is absent from `proto/persisted.exs`, the migrations dir, and
  `lib/stacks/gen/`. It must be **created** here (or in a sibling), not merely
  annotated.

---

## Decision

### 1. Schema for the new tables

All follow the project convention: UUID PK (`:binary_id`), `op` schema prefix,
`utc_datetime_usec` timestamps, `text` for strings. Columns below are the proto
field list; overrides shown are the `proto/persisted.exs` `field_overrides`.

#### `op.embeddings` — user-scoped vectors (PERSONAL)
| Column | Type | Override | Notes |
|--------|------|----------|-------|
| `id` | binary_id PK | — | |
| `user_id` | binary_id FK→`op.users` | `references_table: :users, on_delete: :delete_all, null: false` | erasure reach |
| `source_type` | text | `null: false` | `"shelf"` \| `"blog_post"` \| `"book"` \| `"placement"` (the "source type") |
| `source_id` | binary_id | `ecto_type: :binary_id` (polymorphic, **no** FK) | mirrors `PlacementHistory.from_bookshelf` polymorphic-UUID pattern |
| `title` | text | | the "title" dimension |
| `shelf` | text | | bookshelf name/category the item sits on |
| `content_date` | timestamptz | `ecto_type: :utc_datetime_usec` | the "date" dimension |
| `embedding` | **vector(N)** | ⚠️ see §5 — **not expressible in proto** | pgvector column |
| `created_at`/`updated_at` | timestamptz | `timestamps: :standard` | |

Indexes: FK index on `user_id` (auto); ANN index on `embedding` (HNSW/IVFFlat —
requires the manual migration in §5); optional `(user_id, source_type)`.

#### `op.blog_assistant_sessions` — writing-assistant sessions (PERSONAL)
`id`; `user_id` (FK→users, `on_delete: :delete_all, null: false`);
`status` text default `"active"`; `topic`/`title` text; `model` text (which
assistant model produced the session); `started_at` timestamptz;
`timestamps: :standard`. FK index on `user_id`.

#### `op.turn_feedback` — feedback per assistant turn (PERSONAL, session-child)
`id`; `session_id` (FK→`op.blog_assistant_sessions`,
`on_delete: :delete_all, null: false`); `turn_index` int; `rating` text
(`"up"`/`"down"`); `comment` text; `timestamps: {:standard, updated_at: false}`
(append-only feedback rows, matches `post_book_associations`). FK index on
`session_id`.

#### `op.retrieval_log` — RAG retrieval audit per turn (PERSONAL, session-child)
`id`; `session_id` (FK→`op.blog_assistant_sessions`,
`on_delete: :delete_all, null: false`); `query` text (**user free text — PII-adjacent**);
`retrieved_ids` `{:array, :binary_id}` default `[]`; `scores` `{:array, :float}`
default `[]`; `turn_index` int; `timestamps: {:standard, updated_at: false}`.
FK index on `session_id`.

#### `op.user_book_content_access` — per-user content access (PERSONAL)
`id`; `user_id` (FK→users, `on_delete: :delete_all, null: false`);
`book_id` (FK→`op.books`, `on_delete: :delete_all, null: false`);
`access_type` text default `"granted"`; `granted_at` timestamptz;
`timestamps: {:standard, updated_at: false}`. FK indexes on `user_id`, `book_id`;
recommend a unique index on `(user_id, book_id)`.

#### `op.book_content_chunks` — shared corpus (NON-personal, PRESERVED) — **new table**
`id`; `book_id` (FK→`op.books`, `on_delete: :delete_all, null: false` — the chunk
belongs to the book, **not** to any user); `chunk_index` int; `content` text;
`token_count` int; optionally an `embedding` vector(N) for retrieval (same §5
caveat). `timestamps: :standard`. **No `user_id` column** — this is the property
that makes it survive erasure. FK index on `book_id`.

### 2. FK / cascade directions

| Table | FK | on_delete | Rationale |
|-------|----|-----------|-----------|
| `op.embeddings` | `user_id`→users | **`:delete_all`** | erasure must reach it |
| `op.embeddings` | `source_id` | *(no FK — polymorphic binary_id)* | source can be book/shelf/post; polymorphic like `PlacementHistory` |
| `op.blog_assistant_sessions` | `user_id`→users | **`:delete_all`** | erasure reach |
| `op.turn_feedback` | `session_id`→sessions | **`:delete_all`** | transitively cascades on user delete |
| `op.retrieval_log` | `session_id`→sessions | **`:delete_all`** | transitively cascades on user delete |
| `op.user_book_content_access` | `user_id`→users | **`:delete_all`** | erasure reach |
| `op.user_book_content_access` | `book_id`→books | `:delete_all` | access row is meaningless without the book |
| `op.book_content_chunks` | `book_id`→books | `:delete_all` | chunk lifecycle follows the book |

**No `:nilify_all` on user-scoped tables** — nilify would orphan PII-derived rows
keyed to a deleted user, contradicting erasure (the same reasoning `deletion.ex`
gives for DELETEing rather than marking `revoked_at`). Because every user-scoped
table cascades on `repo.delete(user)`, **#185 needs no new Multi steps** for
these tables — the existing user delete already reaches them. #185's job is to
(a) add a regression test proving the cascade, and (b) leave `book_content_chunks`
untouched.

### 3. Personal-vs-shared classification (4-tier GDPR model)

| Table | Tier | Erasure | Export (#186) |
|-------|------|---------|---------------|
| `op.embeddings` | **personal** (derived from user content) | delete (cascade) | include (or note as derived) |
| `op.blog_assistant_sessions` | **personal** | delete (cascade) | include |
| `op.turn_feedback` | **personal** | delete (cascade) | include |
| `op.retrieval_log` | **personal** (contains user query text) | delete (cascade) | include |
| `op.user_book_content_access` | **personal** | delete (cascade) | include |
| `op.book_content_chunks` | **public / shared — NON-personal** | **PRESERVED** (no user_id, never deleted by erasure) | exclude |

The `book_content_chunks` = shared, NON-personal, PRESERVED classification is
**load-bearing for #185**: it is the invariant that erasure must not touch the
shared corpus. It is annotated here and must be restated in the migration
moduledoc and the #185 deletion test.

### 4. Event-payload contract — DECISION: option (a), UUID-only payloads

Any events emitted by this data model (e.g. a future
`blog_assistant.session_started`, `embedding.indexed`) **MUST carry UUID-only
payloads** — no free-text queries, no embedding vectors, no book content in
`payload`/`metadata`. This is consistent with the established `user.*` contract
resolved in #121 Phase 7 and documented in the `Stacks.Events` moduledoc
(`aggregate_id` is the key; consumers read current state from the row). We do
**not** add new payload-scrubbing beyond the `:scrub_event_log` step that already
exists in `deletion.ex` — that step remains the defence-in-depth safety net.
Rejecting option (b): building payload-scrubbing per-aggregate would duplicate the
existing safety net and invites richer payloads, which is exactly the failure
mode the UUID-only contract prevents. **Guardrail:** whichever issue first emits
one of these events must add a test asserting the payload is UUID-only, matching
the #121 immutability test pattern.

### 5. Proto-generation plan + the vector-column escape hatch

**Manifest entries to add to `proto/persisted.exs`** (`proto_message → table`),
new proto messages in a new `stacks/common/v1/writing_assistant.proto` (or
`embeddings.proto`):

| Proto message | Table | `migration_exists` |
|---------------|-------|--------------------|
| `Embedding` | `op.embeddings` | false (generate) — but see caveat |
| `BlogAssistantSession` | `op.blog_assistant_sessions` | false |
| `TurnFeedback` | `op.turn_feedback` | false |
| `RetrievalLog` | `op.retrieval_log` | false |
| `UserBookContentAccess` | `op.user_book_content_access` | false |
| `BookContentChunk` | `op.book_content_chunks` | false — but see caveat |

`mix proto.sync` then generates the Ecto schema (`lib/stacks/gen/…`), CREATE TABLE
migration, dbt staging model, and `schema.yml` block for each. dbt notes:
- `op.retrieval_log.query` and any `embedding` column → mark `dbt_exclude: true`
  (free-text PII / large vectors are non-analytic; matches how `users`
  `password_hash` etc. are excluded).
- Consider `skip_dbt: true` for `op.embeddings` and `op.book_content_chunks`
  entirely (pure retrieval infra, like the cache tables) unless analytics need
  row counts.

**⚠️ HIGHEST DESIGN RISK — the `embedding` vector column breaks the proto→migration
codegen path.** Confirmed by reading the generator, not inferred:
- pgvector's `vector(N)` is not in the ADR 009 type map, and
  `MigrationGenerator.format_migration_type/1` **raises** on any type it doesn't
  recognise. Proto has no type that maps to `vector`.
- The nearest codegen-expressible representations are `bytes` → `bytea` or
  `repeated float` → `{:array, :float}` (`double precision[]`). **Both lose
  pgvector's ANN index and `<->`/`<=>` distance operators** — i.e. they defeat the
  purpose of an embeddings table.
- pgvector is **not installed** in the stack. Even a hand-written migration needs
  `CREATE EXTENSION IF NOT EXISTS vector` first, which in turn needs the extension
  available in the Postgres image (local Nix/Flox, CI, and Fly Postgres) — an
  **infra prerequisite**, not just a schema one.

**Resolution — hybrid table for the vector-bearing tables.** For `op.embeddings`
(and `op.book_content_chunks` if it carries an embedding), split the column set:
1. Generate the table + all scalar columns via `mix proto.sync` as normal
   (proto message **omits** the vector field).
2. Add the `embedding vector(N)` column via a **separate, hand-written raw-SQL
   migration** using `execute "ALTER TABLE op.embeddings ADD COLUMN embedding
   vector(N)"` + the ANN index, exactly like the `tsvector` precedent. The Ecto
   schema references it via a `Pgvector.Ecto.Vector` custom type in a small
   hand-written extension module (generated schemas take no business types, per
   ADR 009 — so the vector field lives outside the generated struct or via a
   field_override that the generator must be taught to pass through verbatim).
3. Because `--check` compares generated output to files, the vector column must
   live in a file the generator does not own, or `proto.sync` must gain a
   `raw_sql_columns`/`extra_migration_sql` override. **Prefer keeping it out of
   the generator entirely** (separate migration + schema extension) to avoid
   changing the codegen contract in this issue.

**Vector dimension N** is deferred to the build pass and depends on the embedding
model (`384` MiniLM · `768` · `1536` OpenAI-class). pgvector requires a fixed dim
for indexed columns (HNSW/IVFFlat index ≤ 2000 dims). Recommend parameterising via
the migration and picking the model first.

### 6. Open risks / for-review

1. **Vector codegen (highest):** as §5 — the embedding column cannot go through
   `proto.sync`; it needs a manual migration + a pgvector infra dependency +
   possibly a generator enhancement. This is the load-bearing risk for the issue.
2. **pgvector infra:** `CREATE EXTENSION vector` must be enabled in local
   (Nix/Flox Postgres), CI, and Fly Postgres before any embeddings migration can
   run. Confirm Fly's Postgres image ships pgvector (Fly's managed PG / Supabase
   images do; a bare image may not). File as an infra sub-task.
3. **Scope / LOC budget:** 6 tables (5 required + `book_content_chunks`) + proto
   messages + a manual pgvector migration + schema-extension code will **exceed
   the ~300 LOC / >3-tables budget** the issue's own Scope Check flags. **Recommend
   splitting** (see below).
4. **`book_content_chunks` was under-specified** — the issue says "confirm/annotate"
   but it does not exist. It must be created. If it also needs an embedding, it
   inherits the §5 risk.
5. **dbt exposure of query text:** ensure `retrieval_log.query` is `dbt_exclude`d
   so user prompts don't leak into the warehouse.

---

## Recommended split (for the orchestrator to decide)

Split #183 into two build issues, isolating the codegen-breaking vector work:

- **#183a — codegen-clean session cluster (low risk, pure `proto.sync`).**
  `op.blog_assistant_sessions`, `op.turn_feedback`, `op.retrieval_log`,
  `op.user_book_content_access`. All scalar columns, all FK cascades expressible
  in the manifest today. One `proto.sync` run, no infra work. ~150 LOC.
- **#183b — embeddings + shared corpus + pgvector (higher risk, infra-touching).**
  `op.embeddings`, `op.book_content_chunks`, the `CREATE EXTENSION vector` /
  Fly-Postgres infra enablement, the hand-written vector migration, and the
  `Pgvector.Ecto.Vector` schema extension. Depends on the embedding-model choice.

#185 (deletion) can proceed against #183a immediately (cascade test + preserve
`book_content_chunks` once #183b lands). #184/#186 depend on both.

---

## Build-pass phase breakdown

Assuming the split above, the build work is:

1. **Model choice:** pick the embedding model → fixes vector dim N (blocks #183b).
2. **#183a:** add 4 proto messages + 4 manifest entries → `mix proto.sync` →
   review generated migrations/schemas/dbt → `dbt_exclude` the query text →
   `mix proto.sync --check` clean → tests → `just verify`.
3. **Infra:** enable pgvector in local Nix/Flox PG, CI PG, and Fly PG; add
   `CREATE EXTENSION IF NOT EXISTS vector` as the first embeddings migration.
4. **#183b:** proto messages/manifest for the scalar columns of `embeddings` +
   `book_content_chunks` → `proto.sync` → hand-written raw-SQL migration for the
   `vector(N)` column + ANN index → `Pgvector.Ecto.Vector` schema extension →
   tests → `just verify`.
5. **#185 regression test:** assert user delete cascades to all four/five
   user-scoped tables and **leaves `book_content_chunks` intact**; assert emitted
   events (if any) carry UUID-only payloads.

---

## Related

- ADR 007 (protobuf as contract), ADR 009 (proto-to-schema codegen)
- ADR 016 (guardian-db token revocation) — the `revoke_sessions` erasure step
- `docs/agents/standards/migrations.md` (expand–contract, frozen migrations)
- `apps/core/lib/stacks/gdpr/deletion.ex`, `apps/core/lib/stacks/events.ex`
- `proto/persisted.exs` (manifest), `apps/core/lib/mix/tasks/proto_sync/`
- Issue #183; children #184 (consent), #185 (deletion), #186 (export)
