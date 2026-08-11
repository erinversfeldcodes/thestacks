defmodule Core.Repo.Migrations.CreateBookstoreEvents do
  use Ecto.Migration

  def change do
    create table(:bookstore_events, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :store_id, references(:bookstores, type: :binary_id, prefix: "op", on_delete: :nothing),
        null: false

      add :author_id, references(:authors, type: :binary_id, prefix: "op", on_delete: :nothing)
      add :title, :text, null: false
      add :description, :text
      add :event_date, :utc_datetime_usec
      add :location, :text
      add :url, :text
      add :scraped_at, :utc_datetime_usec
    end

    create index(:bookstore_events, [:store_id], prefix: "op")
    create index(:bookstore_events, [:author_id], prefix: "op")
  end
end
