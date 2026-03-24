# Issue #131b: Rewrite Elm Proto Generator

## Summary
Rewrite `scripts/gen-elm-proto.sh` from a stub into a real generator that reads `buf build` JSON descriptors and emits Elm decoder/encoder modules. Must not depend on `Json.Decode.Pipeline`.

## User Stories
N/A — internal tooling.

## Goal
`scripts/gen-elm-proto.sh` takes `.proto` files as input and produces compilable Elm modules as output, with decoders that use `Json.Decode.mapN` + `andThen` (no Pipeline dependency).

## Scope Check
- Does this issue touch more than 3 controllers? No (tooling only).
- Does this issue exceed ~300 lines of production code? Borderline (~200-300 lines of generator logic).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by #131c.

## Technical Requirements

### Generator approach
Read the JSON FileDescriptorSet from `buf build proto/ --output /dev/stdout --as-file-descriptor-set` and emit Elm modules. The generator can be written in Python (simplest — no new deps) or Elixir (Mix task).

### Elm output conventions
- Module path: `Stacks/<Package>/<Version>/<MessageName>.elm` (e.g., `Stacks/Common/V1/Book.elm`)
- Use `Json.Decode.mapN` for messages with ≤8 fields
- Use `andThen` accumulator pattern for messages with >8 fields:
  ```elm
  decoder =
      Decode.map8 (\a b c d e f g h -> { a=a, b=b, ... })
          (field1) ... (field8)
          |> Decode.andThen (\partial ->
              Decode.map (\i -> { partial | field9 = i })
                  (field9)
          )
  ```
- Enums decode from lowercase strings (matching API output, not SCREAMING_SNAKE_CASE)
- Optional fields use `Decode.maybe (Decode.field "name" decoder)`
- Repeated fields use `Decode.field "name" (Decode.list innerDecoder)` with `oneOf [field, succeed []]` fallback
- `google.protobuf.Timestamp` → `String` (RFC3339)
- `google.protobuf.Struct` → `Decode.value` (opaque JSON)
- Encoders use `Json.Encode.object` with `json_name` keys

### Proto type → Elm type mapping
| Proto type | Elm type | Decoder |
|-----------|----------|---------|
| string | String | Decode.string |
| int32/int64/uint32 | Int | Decode.int |
| float/double | Float | Decode.float |
| bool | Bool | Decode.bool |
| bytes | String | Decode.string (base64) |
| enum | Custom ADT | Custom decoder from lowercase strings |
| message | Record | Nested decoder |
| repeated T | List T | Decode.list innerDecoder |
| optional T | Maybe T | Decode.maybe |
| google.protobuf.Timestamp | String | Decode.string |
| google.protobuf.Struct | Decode.Value | Decode.value |

### `--check` mode
`scripts/gen-elm-proto.sh --check` generates in memory (or to temp dir), diffs against `proto/gen/elm/`, exits 0 if identical, exits 1 with diff output if drifted.

## Definition of Done
- [ ] `scripts/gen-elm-proto.sh` generates Elm from all `.proto` files
- [ ] Generated Elm compiles with `elm make` (no Pipeline dependency)
- [ ] `--check` mode works
- [ ] Generator handles: enums, nested messages, optional fields, repeated fields, WKTs
- [ ] Generated output matches the style of existing hand-written proto gen files

## Dependencies
None — can start in parallel with #131a.

## Agent Assignment
protobuf-agent or elm-agent

## Progress Notes
[Updated by agents during execution.]
