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

## Source
elixir-reviewer P3, #210 epic review. Deferred (needs an extension migration).
