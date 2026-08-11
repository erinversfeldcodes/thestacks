defmodule Core.Repo.Migrations.DropRedundantFeedCacheFkIndex do
  @moduledoc """
    Drops the redundant non-unique FK index `feed_cache_bookshelf_id_index` left
    behind by `20260720152621_create_feed_cache`, which created both it and the
    unique `feed_cache_bookshelf_id_unique_index` on the same single column. The
    unique index fully serves FK lookups and is the upsert conflict target, so the
    non-unique one is dead weight.

    The proto generator no longer emits the duplicate for future tables; this
    migration cleans up the already-created one on existing databases.

    `DROP INDEX CONCURRENTLY` cannot run inside a transaction, hence
    `@disable_ddl_transaction` / `@disable_migration_lock` (matching the sibling
    concurrent-index migrations).
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    drop_if_exists index(:feed_cache, [:bookshelf_id],
                     prefix: "op",
                     name: "feed_cache_bookshelf_id_index",
                     concurrently: true
                   )
  end

  def down do
    create_if_not_exists index(:feed_cache, [:bookshelf_id],
                           prefix: "op",
                           name: "feed_cache_bookshelf_id_index",
                           concurrently: true
                         )
  end
end
