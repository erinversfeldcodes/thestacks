defmodule Core.Repo.Migrations.CreateBookshelfPlacements do
  use Ecto.Migration

  def up do
    create table(:bookshelf_placements, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :nothing), null: false
      add :bookshelf_id, references(:bookshelves, type: :binary_id, prefix: "op", on_delete: :delete_all), null: false
      add :position, :integer
      add :placed_at, :utc_datetime_usec
      add :removed_at, :utc_datetime_usec
      add :formats, {:array, :text}
      add :personal_rating, :integer
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:bookshelf_placements, [:bookshelf_id], prefix: "op")

    # Partial unique index: only one active placement per book+bookshelf (where removed_at IS NULL)
    execute("""
    CREATE UNIQUE INDEX bookshelf_placements_book_active_idx
    ON op.bookshelf_placements (book_id, bookshelf_id)
    WHERE removed_at IS NULL
    """)
  end

  def down do
    drop table(:bookshelf_placements, prefix: "op")
  end
end
