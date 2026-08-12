defmodule Core.Repo.Migrations.AddBooksDescriptionTsvectorColumn do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

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
