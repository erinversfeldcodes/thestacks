defmodule Stacks.Accounts do
  @moduledoc """
  Accounts context — user registration, authentication, and retrieval.

  The first user registered on the platform automatically receives the `owner` role.
  Passwords are hashed with Argon2. Authentication returns a Guardian JWT token.
  """

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
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
      {:error, _, reason, _} -> {:error, reason}
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

  defp maybe_assign_owner_role(attrs) do
    user_count = Repo.aggregate(User, :count, :id)

    if user_count == 0 do
      Map.put(attrs, "role", "owner")
    else
      attrs
    end
  end
end
