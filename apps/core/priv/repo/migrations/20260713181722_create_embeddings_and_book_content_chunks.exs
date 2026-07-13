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
    # pgvector must exist before any `vector` column is created. Idempotent so
    # re-running against an env that already has it is a no-op.
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    # ---- op.embeddings — PERSONAL (user-scoped) ----------------------------
    create table(:embeddings, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      # user_id FK → op.users ON DELETE CASCADE: erasure reach. A hard-delete of
      # the user row cascades to their embeddings (see Stacks.GDPR.Deletion).
      add :user_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :source_type, :text, null: false
      # Polymorphic source reference (interpreted per source_type) — no FK.
      add :source_id, :binary_id
      add :title, :text
      add :shelf, :text
      add :content_date, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # 1024-dim vector (Together AI bge-m3). Added via raw SQL — the pgvector
    # `vector` type is not a built-in the migration DSL knows. Torn down by the
    # `drop table` in down/0.
    execute("ALTER TABLE op.embeddings ADD COLUMN embedding vector(1024)")

    create index(:embeddings, [:user_id], prefix: "op")

    # HNSW ANN index with cosine distance. Built on an empty table (instant).
    execute(
      "CREATE INDEX embeddings_embedding_hnsw_idx ON op.embeddings USING hnsw (embedding vector_cosine_ops)"
    )

    # ---- op.book_content_chunks — SHARED, NON-personal (PRESERVED) ---------
    # NO user_id column: nothing to erase, so GDPR erasure preserves this table.
    create table(:book_content_chunks, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      # book_id FK → op.books ON DELETE CASCADE: chunk lifecycle follows the
      # book, never a user.
      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :chunk_index, :integer, null: false
      add :content, :text, null: false
      add :token_count, :integer

      timestamps(type: :utc_datetime_usec)
    end

    execute("ALTER TABLE op.book_content_chunks ADD COLUMN embedding vector(1024)")

    create index(:book_content_chunks, [:book_id], prefix: "op")

    execute(
      "CREATE INDEX book_content_chunks_embedding_hnsw_idx ON op.book_content_chunks USING hnsw (embedding vector_cosine_ops)"
    )
  end

  def down do
    # Dropping each table cascades away its columns (incl. the vector column)
    # and indexes. The `vector` extension is intentionally left installed on
    # rollback (it is cheap, may back other objects, and re-install is a no-op).
    drop table(:book_content_chunks, prefix: "op")
    drop table(:embeddings, prefix: "op")
  end
end
