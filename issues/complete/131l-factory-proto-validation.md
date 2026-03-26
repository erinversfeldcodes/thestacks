# Issue #131l: Validate Test Factories Against Proto Schemas

## Summary
Test factories (`apps/core/test/support/factory.ex`) construct Ecto structs with hand-written field lists. If a proto field is added/removed but the factory isn't updated, tests pass with stale data. Add validation that factory output conforms to proto schemas.

## Goal
Test factories are validated against proto definitions, catching drift between test data and schema.

## Technical Requirements

### Option A: Factory generates from proto
Extend `mix proto.sync` to generate factory templates from proto messages. Each factory builds structs matching the proto field set with sensible defaults.

### Option B: Runtime validation
Add a test helper that validates factory output structs against proto field lists. Run as a compile-time or test-setup check:
```elixir
assert_proto_fields(build(:book), Stacks.Common.V1.Book)
```

### Option C: Factory imports generated defaults
The Elm generator produces `default<TypeName>` functions. Create an equivalent in Elixir — a `Proto.Defaults` module with default values for each proto message. Factories use these defaults as base, overriding only what the test needs.

## Definition of Done
- [ ] Factories validated or generated from proto
- [ ] Adding a required proto field without updating factory causes a test failure
- [ ] All existing tests pass

## Dependencies
- #131h (Ecto schemas are proto-generated)

## Agent Assignment
elixir-agent

## Progress Notes
[Updated by agents during execution.]
