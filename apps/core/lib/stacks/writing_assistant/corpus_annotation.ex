defmodule Stacks.WritingAssistant.CorpusAnnotation do
  @moduledoc """
      Ecto schema for op.corpus_annotations — a per-work OR per-chunk annotation
      on the author's corpus: tags, an exemplar-quality score, a
      `do_not_retrieve` redaction flag (enforced at the retrieval seam), and a
      free-text note. Exactly one of `work_id` / `embedding_id` is set, enforced
      by a DB CHECK constraint.

      GDPR: PERSONAL, user-scoped. Erased on ACCOUNT deletion via the `user_id`
      FK (ON DELETE CASCADE) and on `writing_assistant` CONSENT REVOCATION via
      `Stacks.Workers.WritingAssistantDataPurgeWorker`. The `note` is
      Cloak-encrypted at rest; `tags` stay plaintext so they remain queryable
      (the same call the `do_not_retrieve` boolean makes).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"
  @type t :: %__MODULE__{}

  schema "corpus_annotations" do
    belongs_to :user, Stacks.Accounts.User, type: :binary_id
    belongs_to :work, Stacks.WritingAssistant.ImportedWork, type: :binary_id
    belongs_to :embedding, Stacks.WritingAssistant.Embedding, type: :binary_id
    field :tags, {:array, :string}, default: []
    field :exemplar_quality, :integer
    field :do_not_retrieve, :boolean, default: false
    field :note, Stacks.EncryptedBinary

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
