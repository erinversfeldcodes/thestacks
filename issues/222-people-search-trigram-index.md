# Issue #222: People-search trigram index for ILIKE scaling

## Summary
`Accounts.search_users/2` filters with `ilike(u.display_name, "%term%")`. A
leading-wildcard ILIKE cannot use a btree index, so each search sequentially scans
`op.users` (the platform-visibility predicate and `LIMIT 20` don't avoid the scan).
Fine at current scale; degrades linearly with user count on a user-facing endpoint.

## Goal
People-search stays sub-linear as the user table grows.

## Scope
- Add a GIN trigram index (`pg_trgm`) on `lower(display_name)` and query against it
  (own migration; `pg_trgm` extension may need a superuser/`CREATE EXTENSION`), OR
- Move people-search onto the existing full-text/search infrastructure.
- Keep the SQL-enforced platform-only + bidirectional-block exclusion unchanged.

## Definition of Done
- [ ] Search no longer sequentially scans `op.users`; exclusion semantics unchanged.

## Delegation spec (agent)
**Files:** a new migration `apps/core/priv/repo/migrations/*_add_display_name_trgm_index.exs`;
`apps/core/lib/stacks/accounts.ex` (`search_users/2`).
**Acceptance criteria:**
1. Migration: `CREATE EXTENSION IF NOT EXISTS pg_trgm` then a GIN trigram index on
   `lower(display_name)` in the `op` schema (build `CONCURRENTLY` under
   `@disable_ddl_transaction true` / `@disable_migration_lock true`, matching the handle
   index pattern in `20260714200520`). If `CREATE EXTENSION` needs a privilege the app role
   lacks, note it in the migration moduledoc and guard with `IF NOT EXISTS`.
2. `search_users/2` still returns the SAME rows — `profile_visibility == "platform"` +
   `ilike(lower(display_name), lower(pattern))` + bidirectional block-exclusion (`NOT EXISTS`)
   + `LIMIT 20`. The exclusion stays in SQL. Only the index/predicate shape changes so the
   GIN index is usable.
3. The existing `accounts_test.exs` `search_users` matrix (platform-only, ILIKE case/substring,
   ghost excluded, blocked both directions, blank, wildcard-literal) stays green.
**Verify:** `just run mix test test/stacks/accounts_test.exs`; `just run just verify`
(migration must apply cleanly on a fresh test DB — the concurrent index needs the disable flags).
Optional: `EXPLAIN` shows the GIN index is used.

## Source
elixir-reviewer P3, #210 epic review. Deferred (needs an extension migration).
