# Issue #102: Isolate Broadway PricePipeline in Own Supervisor

## Summary
`PricePipeline` (Broadway) is a direct child of the top-level application supervisor. If it crashes repeatedly, it could hit `max_restarts` on the top-level supervisor and take down the entire application including the web endpoint.

## Goal
Move PricePipeline into its own child Supervisor with its own restart intensity, isolating pipeline failures from the rest of the application.

## Scope Check
- Modify application.ex
- ~15 LOC

## Technical Requirements
- Create a `Supervisor` child wrapping PricePipeline
- Set appropriate `max_restarts` / `max_seconds` for the inner supervisor
- The outer application supervisor continues with `one_for_one`
- Test: killing the pipeline repeatedly should not crash the endpoint

## Definition of Done
- [ ] PricePipeline is in its own supervisor subtree
- [ ] Application survives pipeline crash storms
- [ ] `just verify` passes

## Priority
P2 — fix during Wave E

## Agent Assignment
elixir-agent
