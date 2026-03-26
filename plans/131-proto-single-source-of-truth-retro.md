# Retrospective: Proto as Single Source of Truth
**Issue**: #131 (sub-issues 131a–131l)
**Date**: 2026-03-26
**Phases completed**: 12
**Agents involved**: orchestrator, elixir-agent, elm-agent, python-agent

---

## What Worked Well

- **`buf build --as-file-descriptor-set` over a text parser.** The JSON FileDescriptorSet handles WKTs, imports, nested types, and repeated labels without custom parsing. Settled the approach immediately.
- **Manifest file over custom proto options.** Persistence metadata (table name, schema prefix, NOT NULL, indexes) in `proto/persisted.exs` keeps `.proto` files focused on the wire format. Clean separation.
- **Read-only generated schemas.** No changesets, no business logic in generated files meant they could be overwritten freely with zero risk to domain logic.
- **Golden snapshot tests.** `ProtoDecoderTest.elm` (2,578 lines) and `proto_json_test.exs` (911 lines, 51 tests) caught three real field mismatches during the migration that would have been silent runtime bugs.
- **`mix proto.sync --check` as a CI gate.** Caught stale generated files twice during the PR without any manual auditing.
- **`locals_without_parens` in `Code.format_string!/2`.** Passing the Ecto DSL locals list made generate/check output identical, solving the false drift problem cleanly.

---

## What Caused Friction

- **Bootstrap circular dependency.** Generated Ecto schemas cannot be gitignored (unlike Elm decoders). Elixir's `%Module{}` struct expansion requires the module to already be compiled; on a fresh clone, `mix compile` fails before any generator can run. The resolution — check generated schemas into git, enforce currency with `--check` CI — is correct but cost investigation time. Documented in ADR 009.

- **`add_if_not_exists` and duplicate migration timestamps.** Migration `20260319000002` had columns that were already manually applied to the Neon production branch. The deploy failed with `duplicate_column`. Switching to `add_if_not_exists` fixed the idempotency problem, but the column scanner regex (`~r/^\s+add\s+:(\w+)/m`) didn't match the new form, so `mix proto.sync` kept treating those columns as missing and generating new migration files — all with the same timestamp, causing a "migration version duplicated" failure on the next deploy. Two deploy failures, one root cause.

- **Proto3 optional synthetic oneofs.** Fields marked `optional` in proto3 syntax compile to a synthetic oneof containing one field. The Python generator initially wrapped every oneof field as `Optional[T]`, producing spurious optionals on plain required fields. Fix: check the `proto3Optional` flag on the oneof descriptor.

- **`Code.format_string!` without DSL context.** The generator applied `Code.format_string!/1` to produced output. Without `locals_without_parens`, the formatter converts `field :name, :type` to `field(:name, :type)`. Disk files (formatted by `mix format`, which reads `import_deps: [:ecto]`) retained the non-parenthesised form. Every generated file showed false drift in `--check` mode until the DSL locals were passed explicitly.

- **`Decode.maybe` vs `Decode.nullable`.** `Decode.maybe placementDecoder` passed JSON `null` to the proto-generated decoder, which always succeeds (every field falls back to a default via `D.oneOf`). Result: `Just <empty struct>` instead of `Nothing` for unplaced books. Caught by E2E tests. `Decode.nullable` correctly maps JSON `null` → `Nothing` before the decoder runs.

- **Issue #080 was scoped to the symptom, not the principle.** Issue #080 fixed the Ecto/dbt drift problem for raw ingestion tables. But `docs/technical-architecture.md` already described proto-driven code generation for four languages (Elixir, Python, Rust, Elm) and the contract-first derived data pattern at every service boundary. The issue was written from the triggering bug (`stg_post_book_associations`) rather than from the architecture document. The remaining seven categories of hand-written artifacts — Elm decoders, Elm encoders, ProtoJSON serializer, Python models, Rust types, factory validation, CI enforcement — became a separate 12-sub-issue epic instead of tracked follow-ups created at the same time as #080.

---

## What Should Change in the Agent System

| File | Change | Addresses |
|------|--------|-----------|
| `issues/TEMPLATE.md` | Add a **"Full scope of this principle"** section. When an issue enacts an architectural principle, list every place in the codebase where that principle applies and mark each as *in scope*, *deferred to #NNN*, or *excluded (reason)*. | Issue #080 scoped to symptom |
| `issues/TEMPLATE.md` | Add a **"Architecture alignment"** checklist item: before writing the Definition of Done, search `docs/technical-architecture.md` for the area being changed. If the architecture already describes an intended end state, the DoD must be consistent with it — not a partial step that leaves the rest untracked. | Issue #080 missed arch doc |
| `docs/agents/orchestrator-agent.md` | When accepting an ADR, immediately audit for implementation gaps: list every existing hand-written artifact the ADR's principle would make redundant and create issues for each. ADR acceptance is not implementation. | ADR 007 accepted without full issue coverage |
| `docs/agents/elixir-agent.md` | When generating code that will be compared to disk files (generate/check parity), test the `--check` path before the generate path. False drift from formatter mismatches is easier to catch before the generate mode is working than after. | `Code.format_string!` friction |
| `docs/agents/elixir-agent.md` | When writing a migration that may have been manually pre-applied to a shared DB branch, default to `add_if_not_exists` and update any column scanner regexes in the same commit. | Duplicate migration timestamps |

---

## Suggested Issues

- [ ] Update `issues/TEMPLATE.md` with "Full scope of this principle" section and "Architecture alignment" checklist
- [ ] Audit `docs/technical-architecture.md` for other intended end states that don't yet have corresponding implementation issues — proto-driven development was not the only gap
