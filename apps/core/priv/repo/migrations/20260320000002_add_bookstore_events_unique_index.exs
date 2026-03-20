defmodule Core.Repo.Migrations.AddBookstoreEventsUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:bookstore_events, [:store_id, :title, :event_date], prefix: "op")
    create unique_index(:third_space_events, [:space_id, :title, :event_date], prefix: "op")
  end
end
