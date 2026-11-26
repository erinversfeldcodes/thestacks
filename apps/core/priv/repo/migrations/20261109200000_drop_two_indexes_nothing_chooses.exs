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
      corrected later. `lint-migrations.sh` flags column removals, table drops,
      renames, nullability tightening and column type changes. Its table-drop
      pattern requires the word "table", so an index drop falls through —
      correctly. The expand–contract reasoning the annotation exists to force
      ("no N-1 reader still reads the doomed shape") has no analogue for an
      index: no code names one, dropping it loses no data, and re-creating it
      restores the previous state exactly. Adding the annotation to be safe
      would make the rule incoherent.

      ⛔ THAT PARAGRAPH IS DESCRIBED RATHER THAN QUOTED, AND THAT IS LOAD-BEARING.
      An earlier version listed the gate's patterns as literal code spans, and
      `lint-migrations.sh` went RED on this file for a column-removal pattern
      and two column-alteration patterns — none of which this migration
      performs. Its DSL regexes
      scan the whole file; the heredoc strip runs only before SQL-literal
      extraction, and the comment strip only removes lines starting with `#`, so
      a `@moduledoc` is scanned like code. An explanation of why a pattern does
      not apply must not contain the pattern.

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

  # ⛔ THE `down` DROPS BEFORE IT CREATES, AND `IF NOT EXISTS` IS THE REASON
  # RATHER THAN THE MITIGATION.
  #
  # Measured against an existing INVALID index: `CREATE INDEX CONCURRENTLY IF
  # NOT EXISTS` emits `NOTICE: relation already exists, skipping`, reports
  # `CREATE INDEX` — i.e. SUCCESS — and leaves an index that is both
  # `indisvalid = f` and not the one asked for. Without `if_not_exists` you at
  # least get a loud `ERROR: relation already exists`.
  #
  # ⚖️ And the asymmetry runs toward the `down`, not away from it: a `down` runs
  # exactly when something has already gone wrong, usually under time pressure,
  # so a silent wrong-index outcome is worst here.
  def down do
    execute("SET lock_timeout = '5s'")

    drop_if_exists index(:post_book_associations, [:post_id],
                     prefix: "op",
                     concurrently: true
                   )

    drop_if_exists index(:llm_call_log, [:outcome], prefix: "op", concurrently: true)

    create_if_not_exists index(:post_book_associations, [:post_id],
                           prefix: "op",
                           concurrently: true
                         )

    create_if_not_exists index(:llm_call_log, [:outcome], prefix: "op", concurrently: true)
  end
end
