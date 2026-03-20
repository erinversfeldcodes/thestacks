# Issue #080: Proto-to-Schema Codegen — Completion Report

**Status:** Complete
**Date:** 2026-03-20
**Branch:** feat/wave_b

## What was delivered

`mix proto.sync` — a Mix task that generates Ecto schemas, dbt staging models, and Ecto migrations from Protobuf descriptors, eliminating the triple-duplication of field lists across proto, Ecto, and dbt layers.

### Artifacts

| Module | Purpose |
|--------|---------|
| `Mix.Tasks.Proto.Sync` | Main task — generate and --check modes |
| `Mix.Tasks.ProtoSync.Manifest` | Loads/validates `proto/persisted.exs` |
| `Mix.Tasks.ProtoSync.Descriptor` | Shells out to `buf build`, parses JSON FileDescriptorSet |
| `Mix.Tasks.ProtoSync.TypeMapper` | Proto → Ecto schema types AND proto → migration types |
| `Mix.Tasks.ProtoSync.EctoGenerator` | Generates read-only Ecto schema modules |
| `Mix.Tasks.ProtoSync.DbtGenerator` | Generates dbt staging SQL views |
| `Mix.Tasks.ProtoSync.MigrationGenerator` | Generates CREATE TABLE and ADD COLUMN migrations |
| `Mix.Tasks.ProtoSync.DriftChecker` | Content comparison with myers diff |

### Proof-of-concept tables

- **event_log** — retrofit of existing table (EventEnvelope proto)
- **source_health_checks** — new proto for existing table, changeset moved to Monitoring context

### Key design decisions

1. **Manifest file over custom proto options** — persistence metadata is an Elixir/Postgres concern, not a wire contract property
2. **Generated schemas are read-only** — no changesets, no @derive; context modules own business logic
3. **Schemas checked into git** — bootstrap problem prevents build-time-only generation (documented in ADR 009)
4. **Migrations are sequential history** — never regenerated, always committed

## Definition of Done

- [x] Manifest file identifies persisted messages
- [x] `mix proto.sync` generates migration, Ecto schema, and dbt staging model
- [x] `mix proto.sync --check` exits non-zero on drift (CI integration)
- [x] Type mapping covers all proto scalar types + Timestamp + bytes (including fixed-width)
- [x] Generated migrations follow project conventions
- [x] Generated dbt models follow project conventions
- [x] Two existing raw tables retrofitted as proof-of-concept
- [x] `buf lint`, `mix test`, `dbt run + test` all pass
- [x] Type mapping documented in ADR 009 (technical-architecture.md update deferred to separate commit)

## Verification

- 48 proto_sync tests, 0 failures
- 697 total tests, 0 failures
- 165 dbt tests, 0 failures
- `mix credo --strict` clean
- `buf lint` clean
- `mix proto.sync --check` passes
- Fresh database: drop → create → migrate → seed → test — all green

## Review cycle

5 reviewers × 2 rounds:
- Round 1: 4 NEEDS_REVISION, 1 APPROVED (PE)
- Round 2: 5 APPROVED (after fixing fixed-width types, @spec, ADR, diff algorithm, tests, vestigial files)
