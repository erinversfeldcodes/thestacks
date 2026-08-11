defmodule Core.Repo.Migrations.CreateBookEditions do
  @moduledoc """
    Works/Editions data model migration.

    Transforms `op.books` from an edition-level table (one row per ISBN) into a
    work-level table (one row per logical book). Edition-specific columns move to
    the new `op.book_editions` table.

    Pre-production: we drop columns freely rather than migrating data.
  """

  use Ecto.Migration

  def change do
    create table(:book_editions, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :book_id, references(:books, type: :binary_id, on_delete: :delete_all), null: false
      add :isbn, :text, null: false
      add :format_label, :text
      add :cover_image_url, :text
      add :page_count, :integer
      add :publisher, :text
      add :publication_year, :integer
      add :open_library_id, :text
      add :google_books_id, :text
      add :is_primary, :boolean, default: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create unique_index(:book_editions, [:isbn], prefix: "op")
    create index(:book_editions, [:book_id], prefix: "op")

    create unique_index(:book_editions, [:book_id],
             prefix: "op",
             where: "is_primary = true",
             name: "book_editions_one_primary_per_book"
           )

    drop_if_exists index(:books, [:isbn], prefix: "op")

    alter table(:books, prefix: "op") do
      remove :isbn, :text
      remove :cover_image_url, :text
      remove :page_count, :integer
      remove :publisher, :text
      remove :publication_year, :integer
      remove :open_library_id, :text
      remove :google_books_id, :text
    end

    alter table(:uploaded_images, prefix: "op") do
      add :book_edition_id, references(:book_editions, type: :binary_id, on_delete: :nilify_all)
    end

    execute(
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          GRANT SELECT ON op.book_editions TO stacks_dbt;
        END IF;
      END $$;
      """,
      """
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
          REVOKE SELECT ON op.book_editions FROM stacks_dbt;
        END IF;
      END $$;
      """
    )
  end
end
