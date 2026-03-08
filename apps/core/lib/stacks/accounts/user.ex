defmodule Stacks.Accounts.User do
  @moduledoc """
  Schema for op.users table. Represents an authenticated platform user.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :email,
             :display_name,
             :role,
             :profile_visibility,
             :age_verified,
             :consent_analytics,
             :created_at,
             :updated_at
           ]}

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :display_name, :string
    field :role, :string, default: "user"
    field :profile_visibility, :string, default: "owner"
    field :age_verified, :boolean, default: false
    field :consent_analytics, :boolean, default: false
    field :consent_analytics_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:email, :password]
  @optional_fields [:display_name, :role, :profile_visibility, :age_verified]

  @doc "Changeset for registration."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> validate_inclusion(:role, ["owner", "user"])
    |> validate_inclusion(:profile_visibility, ["owner", "group", "platform"])
    |> unique_constraint(:email)
    |> hash_password()
  end

  @doc "Changeset for consent updates."
  def consent_changeset(user, attrs) do
    user
    |> cast(attrs, [:consent_analytics, :consent_analytics_at])
  end

  @doc "Changeset for user settings (age verification)."
  def settings_changeset(user, attrs) do
    user
    |> cast(attrs, [:age_verified])
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset
end
