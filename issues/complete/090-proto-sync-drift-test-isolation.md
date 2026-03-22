# Issue #090: Proto-sync Drift Test Isolation

## Summary
Rewrite the proto-sync drift check test to use a temp directory copy instead of modifying the real generated file.

## Goal
The current drift test writes a `# drift marker` to a committed generated file, checks that `--check` detects it, then restores the original. This has caused recurring CI issues across Waves C and D due to race conditions and stale state.

## Scope Check
- Modify 1 test in proto_sync_test.exs
- ~20 LOC

## Technical Requirements
- Copy the generated file to a temp directory
- Modify the copy, not the original
- Point the drift checker at the temp copy (may require making the checker accept a custom path)
- Or: generate to a temp directory and compare against the real file
- The test must never modify committed source files

## Definition of Done
- [ ] Drift test uses temp files only
- [ ] No committed source files are modified during test runs
- [ ] `just verify` passes
- [ ] Running `just ci elixir` 3 times consecutively produces the same result

## Agent Assignment
elixir-agent
