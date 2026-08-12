defmodule Stacks.WritingAssistant.Embedding do
  @moduledoc """
      Ecto schema for op.embeddings — user-scoped retrieval vectors.

      HAND-WRITTEN, not proto.sync-generated: it carries the pgvector
      `field:embedding, Pgvector.Ecto.Vector` column that proto cannot express.
      The matching manifest entry (proto/persisted.exs) uses `skip_ecto: true`, so
      proto.sync neither generates nor drift-checks this file. The scalar columns
      mirror the `Embedding` proto message; keep them in sync by hand if the proto
      changes (proto.sync --check enforces the migration side).

      GDPR: PERSONAL, user-scoped. Erased via the op.embeddings.user_id FK
      (ON DELETE CASCADE) when Stacks.GDPR.Deletion deletes the user row.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"
  @type t :: %__MODULE__{}

  schema "embeddings" do
    belongs_to :user, Stacks.Accounts.User, type: :binary_id
    field :source_type, :string
    field :source_id, :binary_id
    field :title, :string
    field :shelf, :string
    field :content_date, :utc_datetime_usec
    field :embedding, Pgvector.Ecto.Vector

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
