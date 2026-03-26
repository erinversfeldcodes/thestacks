# Issue #131i: Generate ProtoJSON Serializer from Proto Definitions

## Summary
Replace the hand-written `StacksWeb.ProtoJSON` module with a generated serializer that reads proto message definitions and produces Elixir JSON serialization functions. Currently ProtoJSON is manually kept in sync with proto — adding a field to a proto requires manually updating ProtoJSON.

## Goal
`mix proto.sync` generates `StacksWeb.ProtoJSON.Gen` base serializer functions from the proto FileDescriptorSet. Adding a field to a `.proto` message automatically appears in the Gen base function; the hand-written ProtoJSON module controls which fields are exposed per API endpoint via `Map.take`.

## Technical Requirements

### Generator approach
Extend `mix proto.sync` or create `mix proto.json.sync` that:
1. Reads the buf descriptor (same as Elm generator)
2. For each message in `common/v1/` and `api/v1/`, generates an Elixir function that serializes an Ecto struct to a map matching the proto JSON shape
3. Handles: field name mapping (snake_case), enum values (lowercase strings), nested messages, optional fields, repeated fields
4. Uses `json_name` annotations from proto for output keys

### What stays hand-written
- Controller routing and action logic
- Business logic (which fields to include in which context)
- The 4 placement variants (ProtoJSON.placement_detail vs placement_ref) — these are API-design decisions, not serialization

### What gets generated
- Field extraction from Ecto structs
- Enum value → lowercase string conversion
- Nested message serialization
- Type coercion (DateTime → ISO8601 string, etc.)

## Definition of Done
- [ ] Generator produces serializer functions from proto
- [ ] Generated output matches current ProtoJSON golden snapshot tests (51 tests)
- [ ] `--check` mode for CI drift detection
- [ ] Controllers continue to work without changes
- [ ] All tests pass

## Dependencies
- #131d (ProtoJSON exists with golden tests as reference)
- #131h (Ecto schemas are proto-generated, so serializer can rely on field names matching)

## Agent Assignment
elixir-agent

## Progress Notes
[Updated by agents during execution.]
