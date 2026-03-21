# Issue #082: Proto Sync — Generate schema.yml Column Entries

## Summary
Extend `mix proto.sync` to generate `dbt/models/staging/schema.yml` column entries alongside the staging SQL model, so new proto-backed tables pass `check-model-has-all-columns` without manual YAML editing.

## User Stories
N/A — developer experience improvement.

## Goal
When a developer adds a new table to `proto/persisted.exs` and runs `mix proto.sync`, the generated output includes not just the `.sql` staging model but also the corresponding column block in `schema.yml` — with descriptions derived from proto field comments and appropriate dbt tests (`not_null` for required fields, `unique` on PK, `relationships` for FKs).

## Scope Check
- Single concern: extend one generator module
- No new endpoints
- ~100-150 lines of production code

## Wiring
- [x] This issue is implementation only. No router wiring needed.

## Technical Requirements

1. Add a `SchemaYmlGenerator` module to `apps/core/lib/mix/tasks/proto_sync/`
2. For each table in the manifest, generate a YAML block with:
   - Model name (`stg_<table_name>`)
   - Model description (from proto message leading comment, or a default)
   - Column entries for `id` (PK: `not_null` + `unique`) + all proto fields + timestamp columns
   - `not_null` test on columns with `null: false` in field_overrides
   - `accepted_values` test on enum fields (values from the proto enum definition)
   - `relationships` test on fields with `:binary_id` type override (FK convention)
3. Merge generated entries into the existing `schema.yml` without clobbering hand-written entries for non-proto-backed models
4. `--check` mode should detect when schema.yml is missing columns for proto-backed models
5. Update `technical-architecture.md` "how to add a table" workflow to remove the manual schema.yml step

## Reviewer Context
- `schema.yml` currently has 22 models, only 2 are proto-backed. The generator must preserve all non-proto entries.
- dbt-checkpoint `check-model-has-all-columns` is now a blocking CI check — any missing column fails the build.

## Definition of Done
- [ ] `mix proto.sync` generates schema.yml column entries for proto-backed tables
- [ ] Generated entries include `not_null`, `unique`, `relationships`, and `accepted_values` tests where appropriate
- [ ] Existing non-proto model entries in schema.yml are preserved
- [ ] `mix proto.sync --check` detects schema.yml drift for proto-backed models
- [ ] Tests cover generation and drift detection
- [ ] `just verify` passes

## Dependencies
Issue #080 (proto-to-schema codegen — complete).

## Agent Assignment
elixir-agent (Mix task extension).

## Progress Notes
