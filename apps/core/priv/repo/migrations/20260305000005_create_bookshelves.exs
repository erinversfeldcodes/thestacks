defmodule Core.Repo.Migrations.CreateBookshelves do
  use Ecto.Migration

  def up do
    execute("CREATE TYPE op.bookshelf_name AS ENUM ('antilibrary', 'library', 'wishlist', 'reading_pile', 'looking_for_home')")

    create table(:bookshelves, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all), null: false
      add :name, :bookshelf_name, null: false
      # visibility ceiling: child shelf ≤ parent user profile_visibility
      # visibility_group_id FK to groups added in Phase 6A migration
      add :visibility, :visibility_level, default: "owner", null: false
      add :visibility_group_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bookshelves, [:user_id, :name], prefix: "op")
  end

  def down do
    drop table(:bookshelves, prefix: "op")
    execute("DROP TYPE IF EXISTS op.bookshelf_name")
  end
end
