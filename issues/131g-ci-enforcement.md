# Issue #131g: CI Enforcement for Proto-Generated Elm

## Summary
Add `scripts/gen-elm-proto.sh --check` to CI pipeline so proto/Elm drift is caught automatically.

## User Stories
N/A — CI infrastructure.

## Goal
CI fails if generated Elm files don't match what the proto generator would produce, preventing manual edits to generated code.

## Scope Check
- Does this issue exceed ~300 lines? No (~50 lines of CI script changes).

## Wiring
- [x] This issue is implementation only.

## Technical Requirements

1. Add `gen-elm-proto.sh --check` to `scripts/ci.sh` in the proto CI group (alongside `buf lint` and `buf breaking`)
2. Verify `proto/gen/elm/` files are checked in (Elm has no runtime codegen — generated files must be committed, same as ADR 009 convention)
3. Ensure `.gitignore` does NOT ignore `proto/gen/elm/`
4. Add `gen-elm-proto` recipe to `justfile`

### CI script addition
```bash
# In scripts/ci.sh, proto group:
echo "Checking Elm proto drift..."
bash scripts/gen-elm-proto.sh --check
```

## Definition of Done
- [ ] `scripts/gen-elm-proto.sh --check` runs in CI
- [ ] CI fails on Elm proto drift
- [ ] `proto/gen/elm/` is committed (not gitignored)
- [ ] `justfile` has `gen-elm-proto` recipe
- [ ] Full CI passes

## Dependencies
- #131b (generator with --check mode)
- #131c (generated files committed)
- #131f (Elm app uses generated files)

## Agent Assignment
protobuf-agent

## Progress Notes
[Updated by agents during execution.]
