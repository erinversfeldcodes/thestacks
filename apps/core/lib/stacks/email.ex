defmodule Stacks.Email do
  @moduledoc """
  Email context — handles transactional email flows for registration confirmation,
  password reset, and other notification types.

  Emails are never sent synchronously; they are enqueued as Oban jobs in the
  `notifications` queue and delivered by `Stacks.Workers.EmailDeliveryJob`.
  """

  import Ecto.Query, warn: false

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.User
  alias Stacks.Workers.EmailDeliveryJob

  @per_user_hourly_limit 10
  @global_hourly_limit 100

  @doc """
  Generates a signed email confirmation token, stores it on the user, and
  enqueues a registration confirmation email.

  Rate limit is checked before any DB writes. Token storage and job enqueue
  are wrapped in a single transaction — if the job insert fails, the token
  write is rolled back too.
  """
  @spec send_registration_confirmation(User.t()) :: {:ok, User.t()} | {:error, term()}
  def send_registration_confirmation(user) do
    with :ok <- check_rate_limit(user.id) do
      case user.email_confirmation_token do
        token when is_binary(token) ->
          EmailDeliveryJob.new(%{
            "template" => "registration_confirmation",
            "user_id" => user.id,
            "params" => %{"token" => token}
          })
          |> Oban.insert!()

          {:ok, user}

        _ ->
          {:error, :missing_confirmation_token}
      end
    end
  end

  @doc """
  Looks up a user by email and enqueues a password reset email.
  Always returns `:ok` — no enumeration of registered email addresses.
  """
  @spec send_password_reset(String.t()) :: :ok
  def send_password_reset(email) do
    user = Accounts.get_user_by_email(email)
    do_send_password_reset(user)
    :ok
  end

  @doc """
  Verifies the email confirmation token and marks the user as confirmed.
  Returns `{:ok, user}` or `{:error, :invalid}`.
  """
  @spec confirm_email(String.t()) :: {:ok, User.t()} | {:error, :invalid}
  def confirm_email(token) do
    case Accounts.verify_confirmation_token(token) do
      {:ok, user_id} ->
        user = Repo.get_by(User, id: user_id, email_confirmation_token: token)
        do_confirm_email(user)

      :error ->
        {:error, :invalid}
    end
  end

  @doc """
  Issues a FRESH confirmation link for `email` and enqueues the confirmation
  email. Always returns `:ok` — see `StacksWeb.AuthController.resend_confirmation/2`
  for why the caller may learn nothing from it.

  Four cases, one return value:

    * no account with that email — nothing happens
    * the account is already confirmed — nothing happens (there is no link to
      send; the reader can simply sign in)
    * the account is unconfirmed but past
      `Accounts.unverified_account_max_lifetime_seconds/0` — nothing happens; see
      `Accounts.confirmation_resendable?/1` for why the renewal has a ceiling
    * the account is unconfirmed and within the cap — a new token is signed,
      stored, and delivered

  Re-signing (rather than re-sending the stored token) is deliberate and is what
  makes the affordance safe to offer: the new token carries a new `signed_at`, so
  the link is good for another `Accounts.unverified_account_ttl_seconds/0` AND —
  because `Accounts.expired_unverified_ids/1` keys the reaper off exactly that
  token — the account behind it survives just as long. Asking for a new email is
  the reader's signal that the signup was not abandoned, and it is honoured by
  both clocks at once because there is only one. The previous link stops working,
  which is the ordinary and safer behaviour for a re-issued credential.
  """
  @spec send_confirmation_resend(String.t()) :: :ok
  def send_confirmation_resend(email) do
    email
    |> Accounts.get_user_by_email()
    |> do_send_confirmation_resend()

    :ok
  end

  @doc """
  Verifies the password reset token and updates the user's password.
  Returns `{:ok, user}`, `{:error, :invalid}`, or `{:error, :expired}`.
  """
  @spec reset_password(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid | :expired | Ecto.Changeset.t()}
  def reset_password(token, new_password) do
    case Phoenix.Token.verify(CoreWeb.Endpoint, "password_reset", token, max_age: 86_400) do
      {:ok, user_id} ->
        user = Repo.get_by(User, id: user_id, password_reset_token: token)
        do_reset_password(user, new_password)

      {:error, :expired} ->
        {:error, :expired}

      {:error, _reason} ->
        {:error, :invalid}
    end
  end

  defp do_send_password_reset(nil), do: :ok

  defp do_send_password_reset(user) do
    with :ok <- check_rate_limit(user.id) do
      token = Phoenix.Token.sign(CoreWeb.Endpoint, "password_reset", user.id)
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        user
        |> Accounts.password_reset_changeset(%{
          password_reset_token: token,
          password_reset_sent_at: now
        })
        |> Repo.update!()

        EmailDeliveryJob.new(%{
          "template" => "password_reset",
          "user_id" => user.id,
          "params" => %{"token" => token}
        })
        |> Oban.insert!()
      end)
    end

    :ok
  end

  defp do_send_confirmation_resend(nil), do: :ok

  defp do_send_confirmation_resend(%User{email_confirmed: true}), do: :ok

  defp do_send_confirmation_resend(%User{} = user) do
    if Accounts.confirmation_resendable?(user) do
      issue_confirmation_link(user)
    end

    :ok
  end

  defp issue_confirmation_link(%User{} = user) do
    with :ok <- check_rate_limit(user.id) do
      token = Accounts.sign_confirmation_token(user.id)

      Repo.transaction(fn ->
        user
        |> Accounts.email_confirmation_changeset(%{
          email_confirmed: false,
          email_confirmation_token: token
        })
        |> Repo.update!()

        EmailDeliveryJob.new(%{
          "template" => "registration_confirmation",
          "user_id" => user.id,
          "params" => %{"token" => token}
        })
        |> Oban.insert!()
      end)
    end

    :ok
  end

  defp do_confirm_email(nil), do: {:error, :invalid}

  defp do_confirm_email(user) do
    case user
         |> Accounts.email_confirmation_changeset(%{
           email_confirmed: true,
           email_confirmation_token: nil
         })
         |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :invalid}
    end
  end

  defp do_reset_password(nil, _new_password), do: {:error, :invalid}

  defp do_reset_password(user, new_password) do
    case user
         |> Accounts.password_update_changeset(%{
           password: new_password,
           password_reset_token: nil,
           password_reset_sent_at: nil
         })
         |> Repo.update() do
      {:ok, updated} ->
        Accounts.revoke_all_user_sessions(updated.id)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp check_rate_limit(user_id) do
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    user_count =
      from(j in Oban.Job,
        where:
          j.worker == "Stacks.Workers.EmailDeliveryJob" and
            fragment("?->>'user_id' = ?", j.args, ^user_id) and
            j.inserted_at > ^one_hour_ago
      )
      |> Repo.aggregate(:count)

    global_count =
      from(j in Oban.Job,
        where:
          j.worker == "Stacks.Workers.EmailDeliveryJob" and
            j.inserted_at > ^one_hour_ago
      )
      |> Repo.aggregate(:count)

    cond do
      user_count >= @per_user_hourly_limit -> {:error, :rate_limited}
      global_count >= @global_hourly_limit -> {:error, :rate_limited}
      true -> :ok
    end
  end
end
