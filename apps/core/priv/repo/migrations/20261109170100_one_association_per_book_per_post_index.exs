defmodule Core.Repo.Migrations.OneAssociationPerBookPerPostIndex do
  @moduledoc """
      The unique index behind "one association per book per post".

      ⛔ SEPARATE FROM THE DEDUP DELETE BECAUSE THE TWO SAFETY RULES CONFLICT,
      AND SUPPRESSING EITHER WOULD BE THE WRONG ANSWER.

      `op.post_book_associations` has rows, so a normal `CREATE INDEX` blocks
      every write to it for the duration — and writes to that table are on the
      author-facing path. `concurrently: true` avoids that, and cannot run inside
      a transaction. But `SET LOCAL lock_timeout`, which `security-squawk.sh`
      requires of anything that can wait on a lock, only has effect inside one.

      ⚖️ So the DELETE that collapses existing duplicates stays in the previous
      migration with its timeouts, and the index is built here without a
      transaction. Each statement gets the protection that applies to it rather
      than one rule being waived to satisfy the other.

      ⚠️ `op.ai_spend`'s unique index needs none of this: it is created in the
      same migration as its own empty table, where the brief exclusive lock
      costs nothing.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  @disable_migration_lock true

  # ⚠️ PLAIN `SET`, NOT `SET LOCAL`, AND `statement_timeout = 0` — both per
  # `scripts/lib/squawk-rules.sh`, which documents exactly this case. There is no
  # transaction for a LOCAL setting to scope to under
  # `@disable_ddl_transaction`; and a `statement_timeout` firing part-way through
  # a concurrent build leaves an **INVALID index** behind, which is worse than
  # waiting. The short `lock_timeout` still applies: the brief lock the build
  # takes at each end should not queue behind an in-flight query.
  def up do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    create unique_index(:post_book_associations, [:post_id, :book_id],
             prefix: "op",
             concurrently: true
           )
  end

  def down do
    execute("SET lock_timeout = '5s'")
    execute("SET statement_timeout = 0")

    drop unique_index(:post_book_associations, [:post_id, :book_id],
           prefix: "op",
           concurrently: true
         )
  end
end
