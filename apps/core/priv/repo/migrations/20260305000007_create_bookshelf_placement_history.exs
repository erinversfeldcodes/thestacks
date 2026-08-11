defmodule Core.Repo.Migrations.CreateBookshelfPlacementHistory do
  use Ecto.Migration

  def change do
    create table(:bookshelf_placement_history, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :nothing),
        null: false

      add :from_bookshelf,
          references(:bookshelves, type: :binary_id, prefix: "op", on_delete: :nothing)

      add :to_bookshelf,
          references(:bookshelves, type: :binary_id, prefix: "op", on_delete: :nothing)

      add :moved_at, :utc_datetime_usec, null: false
    end

    create index(:bookshelf_placement_history, [:book_id], prefix: "op")
    create index(:bookshelf_placement_history, [:from_bookshelf], prefix: "op")
    create index(:bookshelf_placement_history, [:to_bookshelf], prefix: "op")
  end
end
