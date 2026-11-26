defmodule Stacks.WritingAssistant.ImportedWork do
  @moduledoc """
      Ecto schema for op.imported_works — a work the author imported into their
      OWN writing corpus (PDF/ePub/DOCX/MD/TXT). The most sensitive text the
      platform holds; same GDPR standing as the corpus it seeds.

      GDPR: PERSONAL, user-scoped. Erased on ACCOUNT deletion via the
      `user_id` FK (ON DELETE CASCADE, reached by `Stacks.GDPR.Deletion`) and on
      `writing_assistant` CONSENT REVOCATION via
      `Stacks.Workers.WritingAssistantDataPurgeWorker`. `title` is
      Cloak-encrypted at rest; `source_sha256` is a content digest, not text.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"
  @type t :: %__MODULE__{}

  schema "imported_works" do
    belongs_to :user, Stacks.Accounts.User, type: :binary_id
    field :title, Stacks.EncryptedBinary
    field :source_format, :string
    field :source_sha256, :string
    field :imported_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
