defmodule Core.Repo.Migrations.AddBooksDescriptionTsvectorColumn do
  use Ecto.Migration

  # `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, so opt out of
  # Ecto's default migration-wide transaction (and its advisory lock, per the
  # Neon idle-socket note on the feed_cache migration).
  @disable_ddl_transaction true
  @disable_migration_lock true

  # #284 deep search: a GENERATED ALWAYS AS stored tsvector over the book
  # description, backed by a GIN index — the same shape as title_tsv
  # (20260307000001), expressed via the Ecto DSL (`add … generated:` +
  # `create index … concurrently:`) so the squawk migration-safety gate stays
  # green. Additive + nullable-safe (coalesce over a nullable description): no
  # expand/contract, no @breaking_ok. The generated column is NOT mapped in
  # proto/persisted.exs (title_tsv isn't either — generated columns live only in
  # the migration, never in the Ecto schema), so no proto.sync change is needed.
  def up do
    alter table(:books, prefix: "op") do
      add :description_tsv, :tsvector,
        generated: "ALWAYS AS (to_tsvector('english', coalesce(description, ''))) STORED"
    end

    create index(:books, [:description_tsv],
             prefix: "op",
             using: "gin",
             name: "idx_books_description_tsv",
             concurrently: true
           )
  end

  def down do
    drop index(:books, [:description_tsv],
           prefix: "op",
           name: "idx_books_description_tsv",
           concurrently: true
         )

    alter table(:books, prefix: "op") do
      remove :description_tsv
    end
  end
end
