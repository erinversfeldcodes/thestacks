# Issue #094: Declare Timex Dependency

## Summary
`Stacks.Workers.FetchAuthorRSSJob` calls `Timex.parse/2` but `timex` is not declared in `apps/core/mix.exs`. It works because it's pulled in transitively. If that transitive path changes, compilation will fail.

## Goal
Either declare `timex` as an explicit dependency or replace the 2 `Timex.parse` calls with stdlib date parsing.

## Scope Check
- Option A: Add 1 line to mix.exs deps — 1 min
- Option B: Replace Timex calls with `NaiveDateTime.from_iso8601` or similar — 15 min

## Technical Requirements
- If keeping timex: add `{:timex, "~> 3.7"}` to `apps/core/mix.exs` deps
- Also clean up `plt_add_apps: [:mix, :timex]` in root `mix.exs` — move timex to the app-level PLT config
- If removing timex: replace `Timex.parse(date_str, "{RFC1123}")` with an Elixir-native alternative

## Definition of Done
- [ ] No undeclared dependency on timex
- [ ] `mix deps.get && mix compile` works from a clean state
- [ ] `just verify` passes

## Priority
P1 — fix before Wave E

## Agent Assignment
elixir-agent
