# Issue #091: Stacks.Config Module

## Summary
Centralise all `Application.get_env` client lookups into a single `Stacks.Config` module.

## Goal
Currently 10+ modules call `Application.get_env(:core, :some_client)` independently. A central config module makes client wiring visible in one place and simplifies config changes.

## Scope Check
- 1 new module
- Modify ~10 modules to use it
- ~80 LOC net

## Technical Requirements
- Create `Stacks.Config` with functions like `storage/0`, `together_client/0`, `scraper_client/0`, `brave_client/0`, `dbt_runner/0`, etc.
- Each function wraps `Application.get_env(:core, :key, DefaultModule)`
- Replace all direct `Application.get_env` calls for client resolution with `Config.xxx()`
- Do NOT move config values themselves — just the lookup

## Definition of Done
- [ ] All client lookups go through Stacks.Config
- [ ] No direct Application.get_env for client modules remains
- [ ] All existing tests pass
- [ ] `just verify` passes

## Dependencies
Suggested in Wave C retro, still unimplemented.

## Agent Assignment
elixir-agent
