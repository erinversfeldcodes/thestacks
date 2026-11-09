defmodule Core.Repo.Migrations.DropTwoIndexesNothingChooses do
  @moduledoc """
      Drop `post_book_associations_post_id_index` and `llm_call_log_outcome_index`.

      ⛔ BOTH COST A WRITE AND SERVE NOTHING, for different reasons.

      **(a) `post_book_associations_post_id_index` is subsumed.** `post_id` is
      the leading column of the unique `(post_id, book_id)` index added the same
      day, so the composite answers every predicate the single-column index
      answered. Measured here rather than assumed, at 20,000 rows across 400
      posts, after `ANALYZE`:

          -- both indexes present
          Index Scan using post_book_associations_post_id_book_id_index
            Index Cond: (post_id = '…0007')
          -- single-column index dropped
          Index Scan using post_book_associations_post_id_book_id_index
            Index Cond: (post_id = '…0007')

      The planner chose the composite while both existed, and the plan is
      unchanged without the other one. That is write amplification on the
      author-facing association write path for nothing.

      **(b) `llm_call_log_outcome_index` has no reader at all.** Nothing filters
      this table on `outcome` — its only query is
      `Blog.latest_association_outcome/1`, which filters `post_id` and orders
      `created_at DESC`. At five distinct values the planner would rarely choose
      it even once a query existed, and this is an append-only table, so the
      index is pure insert cost.

      ⚖️ Dropped `concurrently`, which is why `@disable_ddl_transaction` and
      `@disable_migration_lock` are set. A plain `DROP INDEX` takes ACCESS
      EXCLUSIVE on `op.post_book_associations` — the author-facing write path —
      for the same reason the composite was built concurrently in the first
      place.

      ⚠️ No `@breaking_ok`, deliberately, and this is not an oversight to be
      corrected later: `lint-migrations.sh`'s destructive patterns are
      `remove :col`, `drop_column`, `drop … table`, `rename`, `modify … null:
      false`, `modify :col, :type`, and the SQL-literal equivalents. Its
      table-drop pattern requires the word `table`, so `drop index` falls
      through — correctly. The expand–contract reasoning the annotation exists
      to force ("no N-1 reader still reads the doomed shape") has no analogue
      for an index: no code names one, dropping it loses no data, and
      re-creating it restores the previous state exactly.

      ⬛ `lock_timeout` but no `statement_timeout = 0`: there is no long build
      here to be interrupted, and the short lock timeout still matters so the
      drop does not queue behind an in-flight read and stack every writer
      behind itself.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("SET lock_timeout = '5s'")

    drop_if_exists index(:post_book_associations, [:post_id],
                     prefix: "op",
                     concurrently: true
                   )

    drop_if_exists index(:llm_call_log, [:outcome], prefix: "op", concurrently: true)
  end

  def down do
    execute("SET lock_timeout = '5s'")

    create_if_not_exists index(:post_book_associations, [:post_id],
                           prefix: "op",
                           concurrently: true
                         )

    create_if_not_exists index(:llm_call_log, [:outcome], prefix: "op", concurrently: true)
  end
end
