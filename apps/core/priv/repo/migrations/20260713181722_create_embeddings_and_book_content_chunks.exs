defmodule Core.Repo.Migrations.CreateEmbeddingsAndBookContentChunks do
  @moduledoc """
  Hand-written (NOT proto.sync-generated) migration for the two pgvector-bearing
  tables of the writing-assistant data model (Issue #183, docs/decisions/017).

  proto.sync cannot express the `vector(1024)` column (proto has no matching
  type; the codegen type-mapper would raise), so these two tables are
  `migration_exists: true` + `skip_ecto: true` in proto/persisted.exs. Their
  scalar columns still match the proto messages (proto.sync --check verifies the
  scalar columns are present here); the `embedding` column is invisible to the
  codegen path and lives only here + in the hand-written Ecto schemas.

  Classification (GDPR):
    op.embeddings          — PERSONAL, user-scoped. user_id FK ON DELETE CASCADE,
                             so Stacks.GDPR.Deletion's `Repo.delete(user)` erases
                             a user's embeddings.
    op.book_content_chunks — SHARED, NON-personal corpus. NO user_id column ⇒
                             PRESERVED by erasure (load-bearing for #185).

  Vector dimension 1024 = Together AI `BAAI/bge-m3` (US-12.2.1). HNSW index with
  `vector_cosine_ops` (bge-m3 produces cosine-normalized embeddings).
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
