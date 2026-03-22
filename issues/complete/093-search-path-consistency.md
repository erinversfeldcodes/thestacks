# Issue #093: Standardise search_path Across Environments

## Summary
Dev/test configs use `search_path: "public,op"` while prod uses `"op,public"`. Unqualified table references resolve differently across environments.

## Goal
All environments use the same search_path order so queries behave identically in dev, test, and prod.

## Scope Check
- Modify 2-3 config files
- ~5 LOC

## Technical Requirements
- Standardise to `"op,public"` everywhere (op first — our tables should take precedence)
- Update `apps/core/config/config.exs` (or dev.exs) and `apps/core/config/test.exs`
- The test.exs comment about schema_migrations needing public first may be outdated — verify by running `mix ecto.migrate` with the new order
- If schema_migrations genuinely needs public first, use an explicit `prefix: "public"` in the migration runner config instead

## Definition of Done
- [ ] All environments use the same search_path order
- [ ] `mix ecto.reset && mix test` passes
- [ ] `just ci elixir` passes

## Priority
P1 — fix before Wave E

## Agent Assignment
elixir-agent
