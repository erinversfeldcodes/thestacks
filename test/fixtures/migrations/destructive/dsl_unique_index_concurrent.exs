defmodule Core.Repo.Migrations.Fixture.DslUniqueIndexConcurrent do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create unique_index(:users, [:handle],
             prefix: "op",
             name: :users_handle_index,
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:users, [:handle], prefix: "op", name: :users_handle_index)
  end
end
