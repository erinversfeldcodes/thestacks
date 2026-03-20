defmodule Core.Repo.Migrations.AddPriceSnapshotsUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:price_snapshots, [:book_id, :store_id], prefix: "op")
  end
end
