# The Stacks — Migration Standards

## Philosophy

Database migrations are **frozen in time**. Once a migration is merged to `main`, its content never changes. This discipline is what makes expand–contract rollback safe: N-1 code must run against N schema without DB surgery.

The migration-safety CI gate (`.github/workflows/ci.yml`, job `migration-safety`) enforces the mechanical parts of this. The rest is cultural.

---

## Expand–Contract

Breaking schema changes (removing a column, renaming, adding `NOT NULL` to existing data) require a **two-PR sequence**:

1. **Expand**: add the new shape alongside the old. Dual-write from code. Old reads still work.
2. **Contract**: drop the old shape *after* the release that stops reading/writing it has been running in production long enough to rule out needing rollback past it.

Adding a column is just one PR if it's nullable or has a safe default. It's *removing* and *renaming* that requires the sequence.

Destructive migrations (drops, renames, NOT NULL tightening) must carry a `@breaking_ok "<reason>"` moduledoc annotation. The reason is free text for humans — `scripts/lint-migrations.sh` rejects destructive ops without it but does not verify the reason's claim. Reviewers must audit the referenced prior commit that removed the code reference.

---

## Anti-Pattern — Don't Import App Modules from Migrations

Migrations must be **self-contained SQL-level DSL**:

```elixir
# GOOD — pure DSL, works forever
def change do
  alter table(:users, prefix: "op") do
    add :display_name, :string
  end
end
```

```elixir
# BAD — references an app module whose shape may change
def change do
  Stacks.Accounts.User
  |> Core.Repo.all()
  |> Enum.each(&backfill/1)
end
```

**Why**: a migration is frozen at its commit. The module it imports is not. Six months later the module may be renamed, split, deleted, or have its shape changed. When a fresh environment replays migrations from scratch (staging bring-up, CI's schema-diff gate, disaster recovery), the migration then references a module that no longer matches — the app fails to compile, or worse, the migration runs with different semantics than it had originally.

The CI schema-diff gate runs two migration sets (main's + HEAD's) against HEAD-built app code. An app-importing migration can silently get different behaviour across the two runs, masking or faking a diff.

### Allowed exceptions
- `Ecto.Migration`-namespaced helpers (`create table`, `alter table`, `execute`, `flush/0`) are stable and always allowed.
- Data backfills belong in `priv/repo/seeds.exs` or a dedicated Mix task, not in migrations. If a data change is truly migration-time (e.g. filling a new NOT NULL column with a computed value), use raw `execute "UPDATE ..."` SQL — not app modules.

### If you must reach into app code during migration-time backfill
Don't. Add the column nullable, ship the release that backfills from the app (an Oban job, a one-off task, or a targeted operator script), then in a later release tighten to `NOT NULL`. This is expand–contract for data, not just schema.

---

## Deletion and Squashing

You *may* delete migrations, but only in these specific cases:

1. **Feature-branch rework**: a migration on an unmerged branch that hasn't hit main — delete and replace freely.
2. **Squashing old migrations into a baseline**: periodically (every few years, not per-release) the migration history can be compacted. Squashing requires a dedicated PR that deletes N migrations and adds 1 equivalent baseline. The `db-breaking` PR label bypasses the schema-diff gate for this case.
3. **Reverting a migration that ran in CI but not prod**: rare. Treat as feature-branch rework since it never reached main's production apply path.

Never delete or edit a migration that has been applied to production. If it was wrong, write a new migration that undoes or fixes it.

---

## CI Enforcement

The `migration-safety` job runs on every PR that touches `apps/core/priv/repo/migrations/` and gates three checks:

1. **squawk** — destructive SQL patterns (DROP COLUMN, RENAME, NOT NULL on existing column).
2. **`scripts/lint-migrations.sh`** — Ecto DSL destructive ops require `@breaking_ok`.
3. **`scripts/check-schema-diff.sh`** — dumps `structure.sql` from `origin/main`'s migration set and from HEAD's, diffs for DROP / RENAME / ALTER TYPE / DROP TYPE / enum value drops. Destructive diffs require the `db-breaking` PR label.

All three must pass before merge.

---

## Related

- `scripts/lint-migrations.sh` — checks `@breaking_ok` annotations
- `scripts/check-schema-diff.sh` — structure diff gate
- `scripts/security-squawk.sh` — squawk wrapper
- `docs/technical-architecture.md` §Deploy Strategy — release + rollback posture
- `docs/runbooks/vision-service-rollback.md` — sibling ordering constraint during rollback
