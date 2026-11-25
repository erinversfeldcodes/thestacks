defmodule Stacks.WritingAssistant.Embedding do
  @moduledoc """
      Ecto schema for op.embeddings — user-scoped writing-assistant retrieval
      vectors over the user's own content (shelves, blog posts, books,
      placements, imported works), plus the §2.3 item-0 chunk substrate.

      HAND-WRITTEN, not proto.sync-generated. The matching manifest entry
      (proto/persisted.exs) carries `skip_ecto: true` AND `skip_dbt: true`, so
      proto.sync neither generates nor drift-checks this file nor a warehouse
      model — keep the fields in step with the migration by hand.

      §4b.2 AT-REST POSTURE: the vector, the chunk text, and the sensitive
      metadata (title, shelf) are Cloak-encrypted at rest — a plaintext vector
      is a near-complete copy of the corpus. `embedding` is a
      `Stacks.EncryptedVector` (packed float32, AES-GCM); the text columns are
      `Stacks.EncryptedBinary`. Retrieval decrypts top-k and scores in memory;
      there is NO ANN/tsvector index over the corpus.

      GDPR: PERSONAL, user-scoped. Erased on ACCOUNT deletion via the
      op.embeddings.user_id FK (ON DELETE CASCADE) and on `writing_assistant`
      CONSENT REVOCATION via Stacks.Workers.WritingAssistantDataPurgeWorker;
      encryption adds a second erasure guarantee (crypto-shred via the Cloak key).
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
    field :title, Stacks.EncryptedBinary
    field :shelf, Stacks.EncryptedBinary
    field :content_date, :utc_datetime_usec
    field :embedding, Stacks.EncryptedVector
    field :chunk_text, Stacks.EncryptedBinary
    field :chunk_index, :integer
    field :char_start, :integer
    field :char_end, :integer
    field :model, :string
    field :embedding_version, :integer

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
