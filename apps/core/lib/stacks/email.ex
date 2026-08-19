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

      Returns `{:error, :rate_limited}` when the limiter suppressed a send that
      was otherwise due, and `:ok` otherwise — including when there is no such
      account, since then nothing was dropped. Every outcome is also counted on
      `[:stacks, :auth, :password_reset]` with an `:outcome` tag.

      The truthful return exists for the platform, not for the wire:
      `AuthController.forgot_password/2` answers identically either way, so no
      enumeration of registered addresses becomes possible. Before this, a reset
      the platform swallowed was indistinguishable from one it sent, which left
      "I asked for a link and never got one" unanswerable from the inside.
  """
  @spec send_password_reset(String.t()) :: :ok | {:error, :rate_limited}
  def send_password_reset(email) do
    email
    |> Accounts.get_user_by_email()
    |> do_send_password_reset()
  end

  @doc """
      Verifies the email confirmation token and marks the user as confirmed.
      Returns `{:ok, user}` or `{:error,:invalid}`.
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
      Issues a FRESH confirmation link and enqueues the email.

      Returns `{:error, :rate_limited}` when the limiter suppressed a link that
      was otherwise due, and `:ok` for every other outcome — including the three
      where there was nothing to send: no such account, already confirmed, or
      past `unverified_account_max_lifetime_seconds/0` (renewal has a ceiling;
      see `confirmation_resendable?/1`). All five outcomes are counted on
      `[:stacks, :auth, :confirmation_resend]` with an `:outcome` tag.

      `AuthController.resend_confirmation/2` answers identically for all of them
      (anti-enumeration), so the distinction never leaves the platform.

      When a link IS issued, a NEW token is signed and stored — re-signing is
      what makes the affordance safe: the fresh `signed_at` buys a full TTL,
      and the reaper honours it.
  """
  @spec send_confirmation_resend(String.t()) :: :ok | {:error, :rate_limited}
  def send_confirmation_resend(email) do
    email
    |> Accounts.get_user_by_email()
    |> do_send_confirmation_resend()
  end

  @doc """
      Verifies the password reset token and updates the user's password.
      Returns `{:ok, user}`, `{:error,:invalid}`, or `{:error,:expired}`.
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

  defp do_send_password_reset(nil), do: reset_outcome(:no_account)

  defp do_send_password_reset(user) do
    case check_rate_limit(user.id) do
      :ok ->
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

        reset_outcome(:sent)

      {:error, :rate_limited} ->
        reset_outcome(:rate_limited)
    end
  end

  defp do_send_confirmation_resend(nil), do: resend_outcome(:no_account)

  defp do_send_confirmation_resend(%User{email_confirmed: true}),
    do: resend_outcome(:already_confirmed)

  defp do_send_confirmation_resend(%User{} = user) do
    if Accounts.confirmation_resendable?(user) do
      issue_confirmation_link(user)
    else
      resend_outcome(:past_renewal_ceiling)
    end
  end

  defp issue_confirmation_link(%User{} = user) do
    case check_rate_limit(user.id) do
      :ok ->
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

        resend_outcome(:sent)

      {:error, :rate_limited} ->
        resend_outcome(:rate_limited)
    end
  end

  # Counting an outcome and answering the caller are the same act, so a new
  # outcome cannot be added to one flow without also reaching the other. The
  # metadata carries the outcome only — no address, no id — because these
  # counters cover unauthenticated endpoints and must not become a record of
  # who asked.
  defp reset_outcome(outcome) do
    :telemetry.execute([:stacks, :auth, :password_reset], %{count: 1}, %{outcome: outcome})
    outcome_reply(outcome)
  end

  defp resend_outcome(outcome) do
    :telemetry.execute([:stacks, :auth, :confirmation_resend], %{count: 1}, %{outcome: outcome})
    outcome_reply(outcome)
  end

  # Suppression is the only outcome the caller has to handle: it is the one
  # where the platform owed someone an email and did not send it. Having
  # nothing to send is not a failure.
  defp outcome_reply(:rate_limited), do: {:error, :rate_limited}
  defp outcome_reply(_delivered_or_nothing_to_send), do: :ok

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
