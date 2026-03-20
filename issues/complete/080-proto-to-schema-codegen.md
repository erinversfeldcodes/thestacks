# Issue #080: Proto-to-Schema Codegen for Raw Ingestion Tables

## Summary
Build a `mix proto.sync` task that generates Ecto migrations, Ecto schema modules, and dbt staging models from `.proto` message definitions tagged as persisted. Eliminates hand-written triple-duplication of the same field list across three layers.

## User Stories
N/A — internal tooling / developer experience.

## Goal
A single `.proto` message definition is the source of truth for raw ingestion tables. Changing a field in the proto automatically surfaces as a migration diff, an Ecto schema update, and a dbt staging model update. No more drift between layers (e.g., the `updated_at` bug in `stg_post_book_associations`).

## Technical Requirements

**Scope: raw ingestion tables only.**
Not all proto messages map to tables. Only messages at the raw/event boundary — where the table schema IS the wire format, just persisted — should be codegen targets. Domain-specific tables (computed, aggregated, joined) remain hand-written.

**Marking messages for codegen:**
Add a custom proto option `(stacks.persisted) = true` to messages that should generate table schemas, or maintain a manifest file (`proto/persisted.yml`) mapping message names to table names and schemas.

**Generated artifacts per message:**
1. **Ecto migration** — `CREATE TABLE` with columns matching proto fields. Type mapping: `string` → `:text`, `int32/int64` → `:integer`/`:bigint`, `google.protobuf.Timestamp` → `:utc_datetime_usec`, `bytes` → `:binary`, `bool` → `:boolean`, `float/double` → `:float`. All tables get UUID PK + `op` schema prefix per project convention.
2. **Ecto schema module** — struct + basic changeset with required/optional field lists derived from proto field presence rules. No business logic — that stays in context modules.
3. **dbt staging model** — `SELECT` view over the raw table with all fields. File placed in `dbt/models/staging/stg_<table_name>.sql`.

**Diff mode:**
`mix proto.sync --check` compares generated output against existing files and exits non-zero on drift. This runs in CI alongside `buf lint` and `buf breaking`.

**Field evolution:**
- Adding a proto field → generates a new migration (ADD COLUMN), updates schema + dbt model.
- Removing a proto field → warns but does NOT generate a DROP COLUMN (additive-only, per project convention). The dbt model drops the column from its SELECT.
- Renaming → treated as remove + add. Manual migration required.

**Proto type → Postgres type mapping table:**
Document the mapping in the task's moduledoc and in `docs/technical-architecture.md`.

## Definition of Done
- [ ] Custom proto option or manifest file identifies which messages are persisted
- [ ] `mix proto.sync` generates migration, Ecto schema, and dbt staging model
- [ ] `mix proto.sync --check` exits non-zero on drift (CI integration)
- [ ] Type mapping covers all proto scalar types + Timestamp + bytes
- [ ] Generated migrations follow project conventions (UUID PK, `op` prefix, `utc_datetime_usec`)
- [ ] Generated dbt models follow project conventions (`stg_` prefix, materialized as view)
- [ ] At least one existing raw table is retrofitted as a proof-of-concept
- [ ] `buf lint`, `mix test`, and `dbt run + test` all pass
- [ ] Type mapping documented in moduledoc and technical-architecture.md

## Dependencies
Issue #045 (proto schemas exist — complete). Should be implemented before or alongside Issue #052 (dbt intermediate + mart models) so staging models benefit from codegen from the start.

## Agent Assignment
elixir-agent (Mix task + Ecto codegen), with orchestrator coordination for dbt and proto touchpoints.

## Progress Notes
