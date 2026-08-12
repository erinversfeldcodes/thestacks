defmodule Core.Repo.Migrations.CreateReviewSnapshots do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.review_source AS ENUM ('goodreads', 'reddit', 'storygraph', 'other');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    create table(:review_snapshots, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :nothing),
        null: false

      add :source, :review_source, null: false
      add :source_url, :text, null: false
      add :sentiment_score, :float
      add :summary, :text
      add :rating, :float
      add :rating_count, :integer
      add :scraped_at, :utc_datetime_usec, null: false
      add :stale_after, :utc_datetime_usec
    end

    create index(:review_snapshots, [:book_id], prefix: "op")
  end

  def down do
    drop table(:review_snapshots, prefix: "op")
    execute("DROP TYPE IF EXISTS op.review_source")
  end
end
