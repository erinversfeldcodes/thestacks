defmodule Stacks.WritingAssistant.BookContentChunk do
  @moduledoc """
  Ecto schema for op.book_content_chunks — the shared book text corpus used as
  retrieval context (Issue #183).

  HAND-WRITTEN, not proto.sync-generated: it carries the pgvector
  `field :embedding, Pgvector.Ecto.Vector` column that proto cannot express.
  The matching manifest entry (proto/persisted.exs) uses `skip_ecto: true`, so
  proto.sync neither generates nor drift-checks this file. The scalar columns
  mirror the `BookContentChunk` proto message.

  GDPR: SHARED, NON-personal. There is deliberately NO user_id column, so GDPR
  erasure PRESERVES this table (load-bearing invariant for #185). The book_id FK
  is ON DELETE CASCADE — chunks follow the book, never a user.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"
  @type t :: %__MODULE__{}

  schema "book_content_chunks" do
    belongs_to :book, Stacks.Books.Book, type: :binary_id
    field :chunk_index, :integer
    field :content, :string
    field :token_count, :integer
    field :embedding, Pgvector.Ecto.Vector

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
