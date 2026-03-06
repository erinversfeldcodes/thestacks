defmodule Core.Repo.Migrations.CreateMyWritingLinks do
  use Ecto.Migration

  def change do
    create table(:my_writing_links, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :nothing)
      add :title, :text, null: false
      add :url, :text, null: false
      add :tags, {:array, :text}
      add :added_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:my_writing_links, [:book_id], prefix: "op")
  end
end
