defmodule Core.Repo.Migrations.CreateThirdSpaceEvents do
  use Ecto.Migration

  def change do
    create table(:third_space_events, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:third_spaces, type: :binary_id, prefix: "op", on_delete: :nothing), null: false
      add :title, :text, null: false
      add :description, :text
      add :event_date, :utc_datetime_usec
      add :recurrence, :text
      add :related_authors, {:array, :text}
      add :source_url, :text
      add :scraped_at, :utc_datetime_usec
    end

    create index(:third_space_events, [:space_id], prefix: "op")
  end
end
