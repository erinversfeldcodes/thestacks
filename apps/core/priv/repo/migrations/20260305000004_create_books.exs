defmodule Core.Repo.Migrations.CreateBooks do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.visibility_tier AS ENUM ('public', 'age_gated');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    create table(:books, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :isbn, :text, null: false
      add :title, :text, null: false
      add :author_id, references(:authors, type: :binary_id, prefix: "op", on_delete: :nothing)
      add :description, :text
      add :cover_image_url, :text
      add :page_count, :integer
      add :publisher, :text
      add :publication_year, :integer
      add :language, :text
      add :subjects, {:array, :text}
      add :bisac_codes, {:array, :text}
      add :visibility_tier, :visibility_tier, default: "public", null: false
      add :open_library_id, :text
      add :google_books_id, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:books, [:isbn], prefix: "op")
    create index(:books, [:author_id], prefix: "op")

    execute(
      "CREATE INDEX idx_books_title_fts ON op.books USING gin (to_tsvector('english', title))"
    )
  end

  def down do
    drop table(:books, prefix: "op")
    execute("DROP TYPE IF EXISTS op.visibility_tier")
  end
end
