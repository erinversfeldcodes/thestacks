defmodule Core.Repo.Migrations.AddBooksTsvectorColumn do
  use Ecto.Migration

  def up do
    # Add a GENERATED ALWAYS AS stored tsvector column for efficient FTS
    execute("""
    ALTER TABLE op.books
    ADD COLUMN title_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, ''))) STORED
    """)

    # Drop the old functional index and replace with a stored column index
    execute("DROP INDEX IF EXISTS op.idx_books_title_fts")

    execute("""
    CREATE INDEX idx_books_title_tsv ON op.books USING gin (title_tsv)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS op.idx_books_title_tsv")

    execute("ALTER TABLE op.books DROP COLUMN IF EXISTS title_tsv")

    execute("""
    CREATE INDEX idx_books_title_fts ON op.books USING gin (to_tsvector('english', title))
    """)
  end
end
