defmodule Stacks.Accounts do
  @moduledoc """
  Accounts context — user registration, authentication, and retrieval.

  The first user registered on the platform automatically receives the `owner` role.
  Passwords are hashed with Argon2. Authentication returns a Guardian JWT token.
  """

  # Ecto.Multi uses an opaque MapSet internally; dialyzer cannot resolve the
  # opaque subterms after Multi.new() and fires call_without_opaque on every
  # chained call. This is a known false positive.
  @dialyzer :no_opaque

  import Ecto.Changeset

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Accounts.User
  alias Stacks.Events
  alias Stacks.Workers.VisibilityRecapJob

  # ---------------------------------------------------------------------------
  # Changeset functions (migrated from User schema for codegen compatibility)
  # ---------------------------------------------------------------------------

  @registration_required_fields [:email, :password]
  @registration_optional_fields [:display_name, :role, :profile_visibility, :age_verified]

  @doc "Changeset for registration."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, @registration_required_fields ++ @registration_optional_fields)
    |> validate_required(@registration_required_fields)
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

  @doc """
  Returns a user by ID, or nil if not found.
  """
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Returns a user by ID, raising if not found.
  """
  @spec get_user!(binary()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Returns a user by email address, or nil if not found.
  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc """
  Registers a new user. The first user on the platform receives the `owner` role.

  The user is created with `email_confirmed: false` and a confirmation token.
  A confirmation email is sent via `EmailConfirmationHandler` (event-driven)
  and the caller receives `{:ok, user}` where `user.email_confirmed == false`.
  The user must confirm their email before they can authenticate.
  """
  @spec register(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register(attrs) do
    attrs = maybe_assign_owner_role(attrs)

    Multi.new()
    |> Multi.insert(:user, registration_changeset(%User{}, attrs))
    |> Multi.run(:set_confirmation, fn _repo, %{user: user} ->
      token =
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      user
      |> email_confirmation_changeset(%{
        email_confirmed: false,
        email_confirmation_token: token
      })
      |> Repo.update()
    end)
    |> Multi.run(:emit_event, fn _repo, %{set_confirmation: user} ->
      Events.emit_safe(%{
        event_type: "user.registered",
        aggregate_type: "user",
        aggregate_id: user.id,
        payload: %{role: user.role}
      })

      {:ok, user}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{set_confirmation: user}} ->
        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}

      {:error, _, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Authenticates a user by email and password.

  Returns `{:ok, user}` on success. On failure, returns one of:
  - `{:error, :invalid_credentials}` — wrong email or password
  - `{:error, :email_unconfirmed}` — valid credentials but email not confirmed
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials | :email_unconfirmed}
  def authenticate(email, password) do
    with {:ok, user} <- check_password(get_user_by_email(email), password),
         :ok <- check_email_confirmed(user) do
      {:ok, user}
    end
  end

  defp check_password(nil, _password) do
    # Run hash to prevent timing attacks
    Argon2.no_user_verify()
    {:error, :invalid_credentials}
  end

  defp check_password(user, password) do
    if Argon2.verify_pass(password, user.password_hash) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  defp check_email_confirmed(%User{email_confirmed: true}), do: :ok
  defp check_email_confirmed(%User{}), do: {:error, :email_unconfirmed}

  @doc """
  Updates the age_verified flag for a user.
  """
  @spec update_age_verification(binary(), boolean()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_age_verification(user_id, age_verified) when is_boolean(age_verified) do
    user_id
    |> get_user!()
    |> settings_changeset(%{age_verified: age_verified})
    |> Repo.update()
  end

  @doc """
  Updates the profile_visibility setting for a user.
  Accepts "platform" or "owner". Returns {:error, changeset} for invalid values.
  """
  @spec update_profile_visibility(binary(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile_visibility(user_id, visibility) do
    result =
      user_id
      |> get_user!()
      |> profile_visibility_changeset(%{profile_visibility: visibility})
      |> Repo.update()

    case result do
      {:ok, user} ->
        Events.emit_safe(%{
          event_type: "user.profile_visibility_changed",
          aggregate_type: "user",
          aggregate_id: user.id,
          payload: %{visibility: visibility}
        })

        %{"user_id" => user.id, "new_visibility" => visibility}
        |> VisibilityRecapJob.new()
        |> Oban.insert()

        {:ok, user}

      error ->
        error
    end
  end

  @doc """
  Updates the display_name and website_url for a user.
  To change email, supply `email:` and `current_password:` — the current password
  is verified before the email is updated.
  """
  @spec update_profile(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :invalid_password}
  def update_profile(%User{} = user, attrs) do
    if Map.has_key?(attrs, "email") do
      update_profile_with_email(user, attrs)
    else
      user
      |> profile_changeset(attrs)
      |> Repo.update()
      |> tap_emit_profile_updated()
    end
  end

  defp update_profile_with_email(user, attrs) do
    with :ok <- verify_password(user, Map.get(attrs, "current_password")) do
      Multi.new()
      |> Multi.update(:profile, profile_changeset(user, attrs))
      |> Multi.update(:email, fn %{profile: u} ->
        email_changeset(u, %{"email" => attrs["email"]})
      end)
      |> Multi.run(:emit_event, fn _repo, %{email: u} ->
        Events.emit_safe(%{
          event_type: "user.profile_updated",
          aggregate_type: "user",
          aggregate_id: u.id,
          payload: %{display_name: u.display_name}
        })

        {:ok, u}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{email: u}} -> {:ok, u}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  defp tap_emit_profile_updated({:ok, user} = result) do
    Events.emit_safe(%{
      event_type: "user.profile_updated",
      aggregate_type: "user",
      aggregate_id: user.id,
      payload: %{display_name: user.display_name}
    })

    result
  end

  defp tap_emit_profile_updated(error), do: error

  @doc """
  Updates the country_code and city for a user. Emits `user.location_updated` event.
  """
  @spec update_location(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_location(%User{} = user, attrs) do
    result =
      user
      |> location_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        Events.emit_safe(%{
          event_type: "user.location_updated",
          aggregate_type: "user",
          aggregate_id: updated.id,
          payload: %{country_code: updated.country_code, city: updated.city}
        })

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Changes the password for a user. Verifies `current_password` with Argon2 before
  applying the new password. Returns `{:error, :invalid_password}` on mismatch.
  """
  @spec change_password(User.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_password} | {:error, Ecto.Changeset.t()}
  def change_password(%User{} = user, current_password, new_password) do
    with :ok <- verify_password(user, current_password) do
      result =
        user
        |> password_change_changeset(%{"password" => new_password})
        |> Repo.update()

      case result do
        {:ok, updated} ->
          Events.emit_safe(%{
            event_type: "user.password_changed",
            aggregate_type: "user",
            aggregate_id: updated.id,
            payload: %{}
          })

          {:ok, updated}

        error ->
          error
      end
    end
  end

  @doc """
  Updates notification preferences for a user.
  """
  @spec update_notifications(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_notifications(%User{} = user, attrs) do
    result =
      user
      |> notifications_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        Events.emit_safe(%{
          event_type: "user.notifications_updated",
          aggregate_type: "user",
          aggregate_id: updated.id,
          payload: %{
            notify_wishlist_availability: updated.notify_wishlist_availability,
            notify_marketplace: updated.notify_marketplace,
            notify_group_invitations: updated.notify_group_invitations,
            notify_event_matches: updated.notify_event_matches
          }
        })

        {:ok, updated}

      error ->
        error
    end
  end

  defp verify_password(%User{password_hash: hash}, current_password)
       when is_binary(current_password) do
    if Argon2.verify_pass(current_password, hash) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  defp verify_password(_user, _), do: {:error, :invalid_password}

  defp maybe_assign_owner_role(attrs) do
    user_count = Repo.aggregate(User, :count, :id)

    if user_count == 0 do
      Map.put(attrs, "role", "owner")
    else
      attrs
    end
  end
end
