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

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :display_name, :string
    field :role, :string, default: "user"
    field :profile_visibility, :string, default: "owner"
    field :website_url, :string
    field :country_code, :string, default: "ZA"
    field :city, :string
    field :age_verified, :boolean, default: false
    field :consent_analytics, :boolean, default: false
    field :consent_analytics_at, :utc_datetime_usec
    field :onboarding_completed, :boolean, default: false
    field :notify_wishlist_availability, :boolean, default: false
    field :notify_marketplace, :boolean, default: true
    field :notify_group_invitations, :boolean, default: true
    field :notify_event_matches, :boolean, default: false

    field :email_confirmed, :boolean, default: false
    field :email_confirmation_token, :string
    field :password_reset_token, :string
    field :password_reset_sent_at, :utc_datetime_usec

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

  @doc "Changeset for profile update (display_name, website_url)."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :website_url])
    |> validate_length(:website_url, max: 500)
  end

  @doc "Changeset for email update. Requires current_password to be verified externally."
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> unique_constraint(:email)
  end

  @doc "Changeset for location update (country_code, city)."
  def location_changeset(user, attrs) do
    user
    |> cast(attrs, [:country_code, :city])
    |> validate_length(:country_code, is: 2)
    |> validate_length(:city, max: 200)
  end

  @doc "Changeset for password change (new_password). Caller must verify current password externally."
  def password_change_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> hash_password()
  end

  @doc "Changeset for notification preferences."
  def notifications_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :notify_wishlist_availability,
      :notify_marketplace,
      :notify_group_invitations,
      :notify_event_matches
    ])
  end

  @doc "Changeset for profile visibility setting."
  def profile_visibility_changeset(user, attrs) do
    user
    |> cast(attrs, [:profile_visibility])
    |> validate_inclusion(:profile_visibility, ["platform", "owner"])
  end

  @doc "Changeset for email confirmation token storage."
  def email_confirmation_changeset(user, attrs) do
    user
    |> cast(attrs, [:email_confirmation_token, :email_confirmed])
  end

  @doc "Changeset for password reset token storage."
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password_reset_token, :password_reset_sent_at])
  end

  @doc "Changeset for completing a password reset. Validates the new plaintext password before hashing."
  def password_update_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_reset_token, :password_reset_sent_at])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> hash_password()
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset
end
