# Plan: Issue #082 — Proto Sync schema.yml Generation

## Context

`mix proto.sync` currently generates Ecto schemas, dbt staging SQL, and migrations. It does NOT generate schema.yml column entries — those are written manually. dbt-checkpoint's `check-model-has-all-columns` is now a blocking CI gate, so any new proto-backed table that doesn't update schema.yml fails CI.

## Key Decisions

1. **YAML merge, not overwrite** — parse existing schema.yml, replace only proto-backed model blocks, preserve all hand-written entries.
2. **Use YamlElixir for parsing, manual string generation for output** — YAML libraries round-trip poorly (lose comments, change formatting). Generate the proto-backed blocks as strings and splice them into the existing file.
3. **Proto field comments as column descriptions** — extract leading comments from the proto descriptor's `sourceCodeInfo` for each field.
4. **Drift check on the merged model blocks only** — compare generated blocks against what's in schema.yml for proto-backed tables.

## Implementation Steps

### Step 1: Create `SchemaYmlGenerator` module
- `generate/2` — accepts table manifest entry + proto fields, returns YAML string for one model block
- Model name: `stg_#{table.table_name}`
- Columns: `id` (not_null + unique) + proto fields + timestamps
- Tests per column:
  - `null: false` in overrides → `not_null`
  - `:binary_id` ecto_type override → `relationships` (infer parent from table naming convention)
  - Enum fields (TYPE_ENUM in descriptor) → `accepted_values` (extract values from proto enum)
  - PK → `not_null` + `unique`

### Step 2: Create YAML merge logic
- Read existing `schema.yml`
- Split into lines, identify model blocks by `- name: stg_<table_name>` markers
- Replace matched blocks with generated content
- Insert new blocks if model doesn't exist yet
- Preserve all non-proto model blocks unchanged

### Step 3: Integrate into main task
- In `run_generate`: after generating SQL, call `SchemaYmlGenerator` and write merged schema.yml
- In `run_check`: compare generated model blocks against existing schema.yml

### Step 4: Extract enum values from descriptor
- The proto descriptor has `enumType` entries with `value` arrays
- Map field's `typeName` to the enum definition to get accepted values
- Strip the enum prefix (e.g., `HEALTH_STATUS_HEALTHY` → `healthy`)

## File Inventory

### New files
- `apps/core/lib/mix/tasks/proto_sync/schema_yml_generator.ex`
- `apps/core/test/mix/tasks/proto_sync/schema_yml_generator_test.exs` (or add to existing test file)

### Modified files
- `apps/core/lib/mix/tasks/proto_sync.ex` — call SchemaYmlGenerator in generate and check modes
- `dbt/models/staging/schema.yml` — proto-backed model blocks regenerated
