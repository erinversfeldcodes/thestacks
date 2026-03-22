# Issue #086: FallbackController Pattern

## Summary
Replace per-controller error handling with a Phoenix FallbackController for consistent error responses across all endpoints.

## Goal
Currently 7+ controllers have identical error-handling clauses (changeset errors, :unauthorized, :not_found). A FallbackController standardises this and reduces boilerplate.

## Scope Check
- 1 new module (`CoreWeb.FallbackController`)
- Modify ~8 controllers to use `action_fallback`
- ~100 LOC net reduction

## Technical Requirements
- Create `CoreWeb.FallbackController` handling `{:error, %Ecto.Changeset{}}`, `{:error, :not_found}`, `{:error, :unauthorized}`, `{:error, :invalid_transition}`, `{:error, :no_placement}`, `{:error, :visibility_ceiling}`
- Use `StacksWeb.ChangesetHelpers.format_errors/1` for changeset rendering
- Retrofit controllers to return error tuples instead of inline `put_status/json`
- Existing `ChangesetHelpers` module can be absorbed into the FallbackController

## Definition of Done
- [ ] FallbackController handles all common error tuples
- [ ] Controllers use `action_fallback` and return tuples
- [ ] All existing tests pass without modification
- [ ] `just verify` passes

## Agent Assignment
elixir-agent
