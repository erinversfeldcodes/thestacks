defmodule Core.Repo.Migrations.CreateBookshelfPlacements do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.listing_mode AS ENUM ('open_bid', 'closed_bid');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.listing_status AS ENUM ('draft', 'active', 'sold', 'removed', 'expired');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    create table(:bookshelf_placements, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :nothing),
        null: false

      add :bookshelf_id,
          references(:bookshelves, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :position, :integer
      add :placed_at, :utc_datetime_usec
      add :removed_at, :utc_datetime_usec
      add :formats, {:array, :text}
      add :personal_rating, :integer
      add :notes, :text
      add :visibility, :visibility_level, default: "owner", null: false
      add :listing_mode, :listing_mode
      add :listing_status, :listing_status
      add :listing_price_cents, :integer
      add :listing_min_price_cents, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:bookshelf_placements, [:bookshelf_id], prefix: "op")

    execute("""
    CREATE UNIQUE INDEX bookshelf_placements_book_active_idx
    ON op.bookshelf_placements (book_id, bookshelf_id)
    WHERE removed_at IS NULL
    """)
  end

  def down do
    drop table(:bookshelf_placements, prefix: "op")
    execute("DROP TYPE IF EXISTS op.listing_status")
    execute("DROP TYPE IF EXISTS op.listing_mode")
  end
end
