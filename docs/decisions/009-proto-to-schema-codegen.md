# ADR 009: Proto-to-Schema Codegen for Raw Ingestion Tables

**Status:** Accepted
**Date:** 2026-03-20
**Deciders:** Platform owner
**Technical area:** Schema contracts, data engineering, developer experience

---

## Context

The Stacks uses Protobuf as the single source of truth for structured data contracts (ADR 007). The system also maintains Ecto schemas (Elixir), Ecto migrations (Postgres DDL), and dbt staging models (SQL views) for the same data. For tables at the **raw ingestion boundary** — where the stored schema IS the wire format, just persisted — these three artifacts are mechanical translations of the same field list.

Today, all three are written by hand. This creates a triple-duplication problem:

1. A `.proto` message defines the shape.
2. An Ecto migration creates the table with matching columns.
3. An Ecto schema module defines the struct and changeset.
4. A dbt staging model selects all columns from the table.

When any one drifts, the others don't notice. We discovered this in production when `stg_post_book_associations.sql` referenced an `updated_at` column that the migration had explicitly excluded (`updated_at: false`). The dbt model was written by hand and nobody caught the mismatch until `dbt run` failed.

**This class of bug is entirely preventable.** For raw tables whose shape is defined by a proto message, all three downstream artifacts can be generated from the proto.

**Scope distinction — two categories of tables:**

| Category | Example | Proto relationship | Codegen? |
|----------|---------|-------------------|----------|
| **Raw/ingestion** | `event_log`, `uploaded_images`, partner inventory | Table schema = wire format | Yes |
| **Domain/derived** | `post_book_associations`, `bookshelves`, `users` | Internal, business logic shapes the schema | No |

Only the first category is in scope. Domain tables remain hand-written because their shape is driven by business logic, not wire format.

**Options evaluated:**

| Approach | Maintenance cost | Drift risk | Complexity |
|----------|-----------------|------------|------------|
| **Status quo** (hand-write all three) | High — same fields written 3 times | High — `stg_post_book_associations` bug | None |
| **CI drift check only** (parse proto, diff against existing files) | Medium — still hand-written, but drift is caught | Low — CI blocks merge | Low |
| **Full codegen** (`mix proto.sync` generates migration + schema + dbt) | Low — single source of truth | Zero — impossible to drift | Medium |
| **Add `dbt_utils` + dbt codegen** (dbt-side only) | Medium — Ecto still hand-written | Partial — only dbt is synced | Low |

---

## Decision

**Implement `mix proto.sync` — a Mix task that generates Ecto migrations, Ecto schema modules, and dbt staging models from `.proto` messages tagged with a custom option `(stacks.persisted) = true`.**

**Marking messages for codegen:**
```protobuf
import "stacks/options.proto";

message EventEnvelope {
  option (stacks.persisted) = true;
  option (stacks.table_name) = "event_log";
  option (stacks.schema_prefix) = "op";

  string event_type = 1;
  string aggregate_type = 2;
  // ...
}
```

Messages without the `persisted` option are ignored by the codegen.

**Generated artifacts per message:**

1. **Ecto migration** — `CREATE TABLE` with columns matching proto fields. UUID PK, `op` schema prefix, `utc_datetime_usec` timestamps per project convention.
2. **Ecto schema module** — struct with `@primary_key {:id, :binary_id, autogenerate: true}`, basic changeset with required/optional fields derived from proto field presence.
3. **dbt staging model** — `SELECT` view with all columns. Placed at `dbt/models/staging/stg_<table_name>.sql`.

**Type mapping (proto → Postgres):**

| Proto type | Ecto type | Postgres type |
|-----------|-----------|---------------|
| `string` | `:string` | `text` |
| `int32` | `:integer` | `integer` |
| `int64` | `:integer` | `bigint` |
| `float` / `double` | `:float` | `double precision` |
| `bool` | `:boolean` | `boolean` |
| `bytes` | `:binary` | `bytea` |
| `google.protobuf.Timestamp` | `:utc_datetime_usec` | `timestamptz` |
| `map<string, string>` | `:map` | `jsonb` |
| enum | `:string` (stored as text) | `text` |

**CI integration:**
`mix proto.sync --check` compares generated output against existing files and exits non-zero on drift. Runs alongside `buf lint` and `buf breaking` in CI.

**Field evolution rules:**
- Adding a proto field → generates a new migration (ADD COLUMN), updates schema + dbt model.
- Removing a proto field → warns but does NOT generate a DROP COLUMN (additive-only per project convention). The dbt model removes the field from SELECT.
- Renaming → treated as remove + add. Manual migration required.

**Timing:**
Implement before or alongside Issue #052 (dbt intermediate + mart models) so staging models benefit from codegen from the start. This is Phase 1 work — see consolidated roadmap, slot between 1B.1 and the dbt buildout in 1A.

---

## Consequences

**Positive:**
- The `stg_post_book_associations` class of bug becomes impossible for codegen-covered tables.
- Adding a field to a raw table is a single proto change — migration, schema, and dbt model follow automatically.
- CI drift check (`--check` mode) catches any manual edits that diverge from the proto source.
- Reduces onboarding friction — new contributors see one authoritative definition per table, not three.
- The type mapping table serves as living documentation for the proto-to-Postgres contract.

**Negative:**
- Adds a build step (`mix proto.sync`) that must run when `.proto` files change. Same pattern as existing `buf generate` for Elm decoders.
- Custom proto options (`stacks.persisted`, `stacks.table_name`) are non-standard and require an `options.proto` file.
- Not all tables are covered — domain tables remain hand-written. Developers must understand which category a table falls into.
- Generated Ecto schemas are basic (no business logic in changesets). Context modules still own validation and domain rules.

**Relationship to ADR 007:**
This extends ADR 007's principle ("`.proto` files as single source of truth") from wire contracts to storage contracts for the raw ingestion layer. ADR 007 governs what crosses service boundaries; this ADR governs how that data is persisted.
