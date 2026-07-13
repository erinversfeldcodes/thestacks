defmodule Stacks.MFA.UserMFA do
  @moduledoc """
  Ecto schema for the `op.user_mfa` table.

  Stores TOTP enrollment data for a user. The `totp_secret` is encrypted at rest
  using `Stacks.EncryptedBinary`. Recovery codes are stored as SHA-256 hashes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @schema_prefix "op"
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_mfa" do
    field :totp_secret, Stacks.EncryptedBinary
    field :recovery_codes, {:array, :string}
    field :enabled_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :user, Stacks.Accounts.User

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:user_id, :totp_secret, :recovery_codes]
  @optional_fields [:enabled_at, :last_used_at]

  @doc "Changeset for creating or updating a UserMFA record."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(user_mfa, attrs) do
    user_mfa
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
