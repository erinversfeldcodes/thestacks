defmodule Core.Repo.Migrations.BuildThePolicySupportingIndexesWithoutLockingWrites do
  @moduledoc """
      The two partial indexes the cross-user read policies need, built
      `CONCURRENTLY` instead of inside the migration that added the policies.

      ## Why they moved out of `20261020160000`

      They were created in that migration's transaction, so a plain
      `CREATE INDEX` held a lock against WRITES for the duration of each build.
      Both tables are on the request path and `op.bookshelf_placements` is
      written by every shelving action — place, move, reread, abandon, remove —
      so a build of any length stalls the thing the policies exist to serve.

      A concurrent build needs its own transaction. The policies and SECURITY
      DEFINER functions in that migration need to land atomically and cannot
      share one, so the index work moved rather than the policy work.

      ## Why the ordering is safe

      The dependency is PERFORMANCE, not correctness. The policies are enforced
      with or without these indexes; until this migration runs, the reads they
      govern fall back to a sequential scan. Nothing returns a wrong row in
      between, which is what makes "later" an acceptable answer here and would
      not be if the indexes were unique or carried a constraint.

      ## Why `statement_timeout = 0`

      A timeout firing part-way through a concurrent build leaves an INVALID
      index behind — present in the catalogue, unused by the planner, and
      requiring a manual drop. That is worse than not having started, so the
      statement timeout is lifted for the build while `lock_timeout` still
      bounds the brief waits at each end.

      ⚠️ `SET`, not `SET LOCAL`: with `@disable_ddl_transaction` there is no
      surrounding transaction for a LOCAL setting to scope to, and it would
      silently apply to nothing.

      ## On databases that already ran the old form

      `create_if_not_exists` makes this a no-op there: `20261020160000` already
      built both indexes non-concurrently, so a stack migrated before the split
      finds them present and skips. A fresh database gets them here instead.
      Either way the end state is the same two indexes.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    create_if_not_exists index(:bookshelf_placements, [:listing_status],
                           prefix: "op",
                           name: :bookshelf_placements_active_listing_idx,
                           where: "listing_status = 'active' AND removed_at IS NULL",
                           concurrently: true
                         )

    create_if_not_exists index(:bookshelves, [:name],
                           prefix: "op",
                           name: :bookshelves_looking_for_home_idx,
                           where: "name = 'looking_for_home'",
                           concurrently: true
                         )
  end

  def down do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    drop_if_exists index(:bookshelves, [:name],
                     prefix: "op",
                     name: :bookshelves_looking_for_home_idx,
                     concurrently: true
                   )

    drop_if_exists index(:bookshelf_placements, [:listing_status],
                     prefix: "op",
                     name: :bookshelf_placements_active_listing_idx,
                     concurrently: true
                   )
  end
end
