# Issue #131h: Generate Ecto Schemas + dbt Models + Migrations for All Domain Tables

## Summary
Add all domain tables to `proto/persisted.exs` so `mix proto.sync` generates Ecto schemas, dbt staging models, and migrations from proto. Currently only 2/30 schemas are proto-generated (EventLog, SourceHealthCheck). This issue covers the remaining 28.

## Goal
Every operational table's Ecto schema, dbt staging model, and migration is generated from a `.proto` message definition via `mix proto.sync`. Hand-written schemas are replaced by generated ones. Domain logic (changesets, validations, business rules) stays in context modules.

## Scope Check
- Does this issue exceed ~300 lines? Yes — ~28 table entries in persisted.exs, ~28 generated schema files, ~28 dbt models. But all mechanical generation, not hand-written.

## Technical Requirements

### 1. Write .proto messages for tables that don't have them yet
Tables without proto definitions:
- `audit_log` → needs `audit_entry.proto`
- `uploaded_images` → needs addition to `upload.proto` or new `uploaded_image.proto`
- `bookshelf_placement_history` → needs `placement_history.proto` or addition to `placement.proto`
- `bookshelves` → needs `bookshelf.proto` or addition to `placement.proto`
- `discovered_sources` → already has proto in `source_responses.proto` (DiscoveredSource)
- `price_snapshots`, `review_snapshots` → needs enrichment protos
- `groups`, `group_invitations`, `group_members` → needs social protos
- `listings` → already has `listing.proto`
- `offer_messages`, `offer_threads`, `transactions` → needs marketplace protos
- `user_blocks`, `visibility_grants` → needs social protos
- `platform_costs` → needs costs proto
- `third_space_events`, `third_spaces` (if table exists) → needs enrichment protos

### 2. Add all tables to `proto/persisted.exs`
For each table, add a manifest entry mapping proto message → table name, schema prefix, Ecto module path, dbt path, timestamps config, field overrides.

### 3. Run `mix proto.sync` to generate
- Ecto schemas in `apps/core/lib/stacks/gen/`
- dbt staging models in `dbt/models/staging/`
- Migration diffs (new columns, type changes)

### 4. Migrate domain logic from old schemas to context modules
The generated schemas are read-only (no changesets). Move changeset/validation logic from hand-written schema modules to their context modules (e.g., `Stacks.Books`, `Stacks.Shelving`).

### 5. Delete hand-written schema files
Replace `apps/core/lib/stacks/books/book.ex` etc. with the generated `apps/core/lib/stacks/gen/books/book.ex`.

## Definition of Done
- [ ] All 30 tables in `persisted.exs`
- [ ] `mix proto.sync` generates all schemas + dbt models
- [ ] `mix proto.sync --check` passes in CI
- [ ] All hand-written schema files deleted (replaced by gen/)
- [ ] All tests pass
- [ ] `dbt run && dbt test` passes

## Dependencies
- #131a (proto messages exist for domain types)

## Agent Assignment
elixir-agent + dbt-agent

## Progress Notes
[Updated by agents during execution.]
