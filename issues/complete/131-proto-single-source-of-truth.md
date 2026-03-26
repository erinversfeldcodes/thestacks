# Issue #131: Proto as Single Source of Truth — Elm Decoders + Phoenix JSON

## Summary
Make `.proto` files the single source of truth for all wire formats. The Phoenix API should serve Protobuf-shaped JSON, and Elm decoders should be generated from the same `.proto` specs. Eliminates the current drift between hand-written `Types/Book.elm` decoders and the API's ad-hoc JSON format.

## User Stories
N/A — internal architecture / developer experience.

## Goal
A single `.proto` message definition determines:
1. The Ecto schema (already done via #080's `mix proto.sync`)
2. The dbt staging model (already done via #080)
3. The Phoenix JSON response shape (new — controllers use proto-derived serializers)
4. The Elm decoder/encoder (new — generated from proto, replacing hand-written `Types/*.elm`)

Changing a field in the proto automatically surfaces across all four layers. No more hand-maintaining `Types/Book.elm`, `Types/Placement.elm`, etc.

## Scope Check
- Does this issue touch more than 3 controllers? Yes — all controllers that serialize JSON. Split into sub-issues.
- Does this issue exceed ~300 lines of production code? Yes. Split into phases.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete (API response shapes change).
- [ ] This issue is implementation only.

## Technical Requirements

### Phase 1: Elm codegen from proto
- Create `scripts/gen-elm-proto.sh` (referenced in #080 plan but never built)
- Use `buf generate` with an Elm plugin, OR write a generator that reads `buf build --output descriptor.json` and emits Elm modules
- Generated output goes to `proto/gen/elm/` (already in `elm.json` source-directories)
- Replace hand-written `Types/Book.elm`, `Types/Placement.elm`, etc. with imports from generated modules
- Delete `ProtoDecoderTest.elm` (tests generated code) and replace with decoder round-trip tests that verify generated decoders match proto JSON shapes

### Phase 2: Phoenix controllers serve proto-shaped JSON
- Create a `ProtoJSON` serializer module that renders Ecto structs as proto-compatible JSON (field names match `json_name` from `.proto`)
- Migrate controllers from ad-hoc `json(conn, %{book: format_book(book)})` to `json(conn, ProtoJSON.encode(book))`
- This may mean snake_case field names stay (proto JSON uses `json_name` which defaults to snake_case), but the structure must match the proto message shape exactly
- Add `visibility_tier` and other fields that Elm decoders require but controllers currently omit

### Phase 3: Elm app migrates to generated decoders
- Replace `import Types.Book exposing (Book, bookDecoder)` with `import Stacks.Common.V1.Book exposing (Book, decodeBook)`
- Update all call sites in `Api.elm`, page modules, etc.
- Delete hand-written `Types/Book.elm`, `Types/Placement.elm`, `Types/Listing.elm`, `Types/BlogPost.elm`
- Update `UploadTest.elm` and other Elm tests to use generated types

### Phase 4: CI enforcement
- `scripts/gen-elm-proto.sh --check` exits non-zero if generated files differ from disk (same pattern as `mix proto.sync --check`)
- Add to CI pipeline alongside `buf lint` and `buf breaking`
- `proto/gen/elm/` stays in `.gitignore` — CI regenerates on every run

## Reviewer Context
- Current Elm decoders in `Types/Book.elm` use `Decode.field "primary_edition"` (snake_case) — proto JSON also uses snake_case by default, so field names should be compatible
- The `bookDecoder` requires `visibility_tier` via `andThen` with no fallback — the Phoenix controller must include this field
- `ProtoDecoderTest.elm` currently tests the hand-written proto gen files — this will be replaced by round-trip tests
- The `elm.json` already has `"../proto/gen/elm"` in source-directories

## Definition of Done
- [ ] `scripts/gen-elm-proto.sh` generates Elm decoders/encoders from `.proto` files
- [ ] Phoenix controllers serve JSON matching proto message shapes
- [ ] Elm app uses generated decoders (no hand-written `Types/*.elm`)
- [ ] `scripts/gen-elm-proto.sh --check` runs in CI
- [ ] `proto/gen/elm/` in `.gitignore` (generated, not checked in)
- [ ] All Elm tests pass with generated decoders
- [ ] All E2E tests pass (API response shapes unchanged or Elm decoders updated in sync)
- [ ] `buf lint`, `mix test`, `elm-test`, `elm-review` all pass

## Dependencies
- #080 (proto-to-schema codegen — complete)
- Proto files exist for all API response types (may need new `.proto` messages for types not yet defined)

## Agent Assignment
Orchestrator-coordinated: elixir-agent (Phoenix serializers), elm-agent (decoder migration), proto-agent (new proto messages).

## Progress Notes
[Updated by agents during execution.]
