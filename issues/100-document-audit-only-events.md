# Issue #100: Document Audit-Only vs Handler-Wired Events

## Summary
20+ event types are emitted but have no handlers in the Events.Registry. It's unclear which are intentionally audit-only (written to event_log for history) vs which are intended to have handlers added later.

## Goal
Add a comment block to the Registry documenting which events are audit-only and which are awaiting handler implementation.

## Scope Check
- 1 file, ~30 lines of comments
- Research: grep all `emit_safe` calls and cross-reference with registry

## Technical Requirements
- List all emitted event types
- Mark each as: `handler-wired`, `audit-only (intentional)`, or `handler-pending (future)`
- Add the list as a comment block at the top of `registry.ex`

## Definition of Done
- [ ] All event types categorised
- [ ] Registry has documentation comment

## Priority
P2 — fix during Wave E

## Agent Assignment
elixir-agent
