defmodule Core.Repo.Migrations.CreateEmbeddingsAndBookContentChunks do
  @moduledoc """
  Hand-written migration for the two pgvector tables (183, ADR-017):
  proto.sync cannot express `vector(1024)`, so both are
  `migration_exists: true` + `skip_ecto: true` in persisted.exs (scalar
  columns still checked against the proto). GDPR: `op.embeddings` is
  PERSONAL (user-scoped, purged on consent revocation);
  `op.book_content_chunks` is the shared non-personal corpus.
  """

  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create table(:embeddings, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :source_type, :text, null: false
      add :source_id, :binary_id
      add :title, :text
      add :shelf, :text
      add :content_date, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    execute("ALTER TABLE op.embeddings ADD COLUMN embedding vector(1024)")

    create index(:embeddings, [:user_id], prefix: "op")

    execute("""
    -- squawk-ignore require-concurrent-index-creation
    CREATE INDEX embeddings_embedding_hnsw_idx ON op.embeddings USING hnsw (embedding vector_cosine_ops)
    """)

    create table(:book_content_chunks, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :chunk_index, :integer, null: false
      add :content, :text, null: false
      add :token_count, :integer

      timestamps(type: :utc_datetime_usec)
    end

    execute("ALTER TABLE op.book_content_chunks ADD COLUMN embedding vector(1024)")

    create index(:book_content_chunks, [:book_id], prefix: "op")

    execute("""
    -- squawk-ignore require-concurrent-index-creation
    CREATE INDEX book_content_chunks_embedding_hnsw_idx ON op.book_content_chunks USING hnsw (embedding vector_cosine_ops)
    """)
  end

  def down do
    drop table(:book_content_chunks, prefix: "op")
    drop table(:embeddings, prefix: "op")
  end
end
