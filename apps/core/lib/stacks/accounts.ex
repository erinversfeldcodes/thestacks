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

  alias Core.Repo
  alias Ecto.Multi
  alias Stacks.Accounts.User
  alias Stacks.Events

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
  """
  @spec register(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register(attrs) do
    attrs = maybe_assign_owner_role(attrs)

    Multi.new()
    |> Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Multi.run(:emit_event, fn _repo, %{user: user} ->
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
      {:ok, %{user: user}} ->
        maybe_send_confirmation(user)
        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}

      {:error, _, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Authenticates a user by email and password.
  Returns `{:ok, user}` on success, `{:error, :invalid_credentials}` on failure.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate(email, password) do
    user = get_user_by_email(email)
    check_password(user, password)
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

  @doc """
  Updates the age_verified flag for a user.
  """
  @spec update_age_verification(binary(), boolean()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_age_verification(user_id, age_verified) when is_boolean(age_verified) do
    user_id
    |> get_user!()
    |> User.settings_changeset(%{age_verified: age_verified})
    |> Repo.update()
  end

  @doc """
  Updates the profile_visibility setting for a user.
  Accepts "platform" or "owner". Returns {:error, changeset} for invalid values.
  """
  @spec update_profile_visibility(binary(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile_visibility(user_id, visibility) do
    user_id
    |> get_user!()
    |> User.profile_visibility_changeset(%{profile_visibility: visibility})
    |> Repo.update()
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
      |> User.profile_changeset(attrs)
      |> Repo.update()
      |> tap_emit_profile_updated()
    end
  end

  defp update_profile_with_email(user, attrs) do
    with :ok <- verify_password(user, Map.get(attrs, "current_password")) do
      Multi.new()
      |> Multi.update(:profile, User.profile_changeset(user, attrs))
      |> Multi.update(:email, fn %{profile: u} ->
        User.email_changeset(u, %{"email" => attrs["email"]})
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
      |> User.location_changeset(attrs)
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
      user
      |> User.password_change_changeset(%{"password" => new_password})
      |> Repo.update()
    end
  end

  @doc """
  Updates notification preferences for a user.
  """
  @spec update_notifications(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_notifications(%User{} = user, attrs) do
    user
    |> User.notifications_changeset(attrs)
    |> Repo.update()
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

  defp maybe_send_confirmation(user) do
    if Application.get_env(:core, :require_email_confirmation, false) do
      Stacks.Email.send_registration_confirmation(user)
    end
  end

  defp maybe_assign_owner_role(attrs) do
    user_count = Repo.aggregate(User, :count, :id)

    if user_count == 0 do
      Map.put(attrs, "role", "owner")
    else
      attrs
    end
  end
end
