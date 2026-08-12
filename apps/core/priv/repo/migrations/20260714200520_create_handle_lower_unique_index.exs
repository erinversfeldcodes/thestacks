defmodule Core.Repo.Migrations.CreateHandleLowerUniqueIndex do
  @moduledoc """
      Case-insensitive uniqueness for `op.users.handle`, built CONCURRENTLY so it
      never takes a write-blocking lock on the auth hot-path table (split out of
      `20260714200500` per the migration reviewer). Concurrent index builds cannot
      run inside a transaction, hence `@disable_ddl_transaction` /
      `@disable_migration_lock`. Backfill (200500) has already populated every row,
      so there is no NULL-vs-unique race.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create unique_index(:users, ["lower(handle)"],
             prefix: "op",
             name: :users_lower_handle_index,
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:users, ["lower(handle)"],
                     prefix: "op",
                     name: :users_lower_handle_index,
                     concurrently: true
                   )
  end
end
