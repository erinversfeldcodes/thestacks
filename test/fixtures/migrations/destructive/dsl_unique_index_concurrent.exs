defmodule Core.Repo.Migrations.Fixture.DslUniqueIndexConcurrent do
  # #219 no-false-positive fixture: the SAFE twin of dsl_unique_index. Built
  # CONCURRENTLY with an explicit name (mirrors the real
  # 20260714200520_create_handle_lower_unique_index). The shared extractor must
  # render this as a concurrent, named, IF NOT EXISTS index so squawk passes —
  # proving the new DSL parsing does not flag legitimately-safe index builds.
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
