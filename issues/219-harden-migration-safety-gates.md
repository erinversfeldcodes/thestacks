# Issue #219: Harden migration-safety gates — close the DSL/raw-execute blind spot

## Summary
The #210 review found that a `NOT NULL` tighten written as raw
`execute("ALTER TABLE … SET NOT NULL")` evades `scripts/lint-migrations.sh` (which
only pattern-matches the `modify … null: false` DSL), while a DSL
`create unique_index(...)` evades `scripts/security-squawk.sh` (which only lints
SQL inside `execute()` strings). The two gates are complementary but their union
has a hole exactly at the DSL/raw-execute boundary — this epic's migration landed
in it and the required `@breaking_ok` annotation was silently absent with no CI
failure (caught only by human review).

## Goal
Neither gate can be bypassed by choice of syntax.

## Scope
- `lint-migrations.sh`: also detect raw `ALTER … SET NOT NULL` / `DROP COLUMN` /
  `RENAME` inside `execute(...)` strings, not just the `modify`/`remove` DSL.
- `security-squawk.sh` (or a wrapper): parse the migration DSL (`create index`,
  `create unique_index`, `alter table … modify`) too, not only `execute()` SQL —
  or run squawk against the migration's *generated* SQL (`mix ecto.migrate --log-sql`
  dry-run) so both syntaxes are covered.
- Add a regression fixture: a migration using each syntax must fail the gate
  without its annotation.

## Definition of Done
- [ ] Both gates catch destructive ops regardless of DSL-vs-execute syntax.
- [ ] Regression fixtures added; a deliberately-unannotated tighten fails CI.

## Source
Principal-engineer process note, #210 epic review.
