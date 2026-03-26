# Issue #131c: Generate All Elm Proto Modules

## Summary
Run the Elm proto generator (#131b) against all `.proto` files (#131a) to produce the complete set of generated Elm decoder/encoder modules.

## User Stories
N/A — internal tooling.

## Goal
`proto/gen/elm/` contains compilable Elm modules for every `.proto` message, generated (not hand-written).

## Scope Check
- Does this issue exceed ~300 lines of production code? ~1200 lines generated (not hand-written).

## Wiring
- [x] This issue is implementation only. Wired by #131f.

## Technical Requirements

1. Run `scripts/gen-elm-proto.sh`
2. Verify output compiles: `cd frontend && elm make src/Main.elm`
3. Verify `ProtoDecoderTest.elm` still passes (Location + EventBus round-trips)
4. Verify `scripts/gen-elm-proto.sh --check` exits 0

### Expected output files
- `proto/gen/elm/Stacks/Common/V1/Book.elm` (updated: AgeGated, bio)
- `proto/gen/elm/Stacks/Common/V1/Location.elm` (regenerated)
- `proto/gen/elm/Stacks/Common/V1/User.elm` (new)
- `proto/gen/elm/Stacks/Common/V1/Placement.elm` (new)
- `proto/gen/elm/Stacks/Common/V1/Listing.elm` (new)
- `proto/gen/elm/Stacks/Common/V1/Blog.elm` (new)
- `proto/gen/elm/Stacks/Common/V1/Upload.elm` (new)
- `proto/gen/elm/Stacks/Api/V1/Responses.elm` (new)
- `proto/gen/elm/Stacks/Api/V1/Admin.elm` (new)
- `proto/gen/elm/Stacks/Internal/V1/EventBus.elm` (regenerated)
- `proto/gen/elm/Stacks/Monitoring/V1/SourceHealthCheck.elm` (new)

## Definition of Done
- [ ] All proto gen Elm files exist and compile
- [ ] `elm make` succeeds
- [ ] `ProtoDecoderTest.elm` passes
- [ ] `scripts/gen-elm-proto.sh --check` exits 0

## Dependencies
- #131a (proto files exist)
- #131b (generator works)

## Agent Assignment
protobuf-agent

## Progress Notes
[Updated by agents during execution.]
