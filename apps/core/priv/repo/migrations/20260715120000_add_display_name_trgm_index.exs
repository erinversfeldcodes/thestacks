defmodule Core.Repo.Migrations.AddDisplayNameTrgmIndex do
  @moduledoc """
      GIN trigram index on `lower(op.users.display_name)` so people-search
      stops seq-scanning: leading-wildcard `ILIKE '%term%'` can't use
      btree, but `gin_trgm_ops` can serve it; `search_users/2` compares
      against `lower(display_name)` to match the indexed expression. Built
      CONCURRENTLY — `op.users` is an auth hot-path table.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:users, ["lower(display_name) gin_trgm_ops"],
             prefix: "op",
             name: :users_display_name_trgm_index,
             using: "gin",
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:users, ["lower(display_name) gin_trgm_ops"],
                     prefix: "op",
                     name: :users_display_name_trgm_index,
                     concurrently: true
                   )
  end
end
