defmodule Core.Repo.Migrations.Fixture.DslUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:users, [:handle], prefix: "op", concurrently: false)
  end
end
