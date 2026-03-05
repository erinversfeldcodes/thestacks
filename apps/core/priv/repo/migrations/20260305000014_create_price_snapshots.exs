defmodule Core.Repo.Migrations.CreatePriceSnapshots do
  use Ecto.Migration

  def change do
    create table(:price_snapshots, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :nothing), null: false
      add :store_id, references(:bookstores, type: :binary_id, prefix: "op", on_delete: :nothing), null: false
      add :price_cents, :integer, null: false
      add :currency, :text, default: "ZAR"
      add :in_stock, :boolean
      add :url, :text
      add :scraped_at, :utc_datetime_usec, null: false
    end

    create index(:price_snapshots, [:book_id], prefix: "op")
    create index(:price_snapshots, [:store_id], prefix: "op")
  end
end
