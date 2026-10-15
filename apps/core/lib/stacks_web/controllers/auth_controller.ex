defmodule StacksWeb.AuthController do
  @moduledoc """
      Handles authentication endpoints: register, login, logout, and current user.
  """

  use CoreWeb, :controller

  require Logger

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Audit
  alias Stacks.Duration
  alias Stacks.Email
  alias StacksWeb.ProtoJSON

  @doc "POST /api/auth/register — create a new user account and send confirmation email."
  def register(conn, params) do
    case Accounts.register(params) do
      {:ok, user} ->
        Audit.log(user.id, "user.registered",
          resource_type: "user",
          resource_id: user.id,
          ip: get_ip(conn)
        )

        :telemetry.execute([:stacks, :auth, :registration], %{count: 1}, %{result: :ok})

        if Stacks.FeatureFlags.invite_only_registration?() do
          :telemetry.execute([:stacks, :auth, :invite], %{count: 1}, %{result: :ok})
        end

        conn
        |> put_status(201)
        |> json(%{message: "confirmation_email_sent"})

      {:error, invite_error} when is_atom(invite_error) ->
        :telemetry.execute([:stacks, :auth, :invite], %{count: 1}, %{
          result: invite_telemetry_label(invite_error)
        })

        conn
        |> put_status(invite_error_status(invite_error))
        |> json(%{error: Atom.to_string(invite_error)})

      {:error, changeset} ->
        :telemetry.execute([:stacks, :auth, :registration], %{count: 1}, %{result: :error})

        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "POST /api/auth/login — authenticate and return a JWT."
  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate(email, password) do
      {:ok, user} ->
        Audit.log(user.id, "user.login",
          resource_type: "user",
          resource_id: user.id,
          ip: get_ip(conn)
        )

        fid = Ecto.UUID.generate()
        {:ok, token, claims} = Guardian.encode_and_sign(user, %{"family_id" => fid})

        family_attrs = %{
          family_id: fid,
          user_id: user.id,
          current_jti: claims["jti"],
          session_started_at: DateTime.from_unix!(claims["sst"])
        }

        case Accounts.rotate_token_family(family_attrs) do
          {:ok, _family} ->
            :telemetry.execute([:stacks, :auth, :jwt_issued], %{count: 1}, %{context: :login})

            json(conn, %{token: token, user: ProtoJSON.user(user)})

          {:error, reason} ->
            Logger.error("rotate_token_family failed on login: #{inspect(reason)}")
            revoke_refresh_token(token)

            conn
            |> put_status(500)
            |> json(%{error: "internal_error"})
        end

      {:error, :email_unconfirmed} ->
        emit_login_failure(:email_unconfirmed)

        conn
        |> put_status(403)
        |> json(%{error: "email_unconfirmed"})

      {:error, :invalid_credentials} ->
        emit_login_failure(:invalid_credentials)

        conn
        |> put_status(401)
        |> json(%{error: "invalid_credentials"})

      {:error, {:account_locked, retry_after_seconds}} ->
        # Per-account login lockout (). 423 Locked is the standard
        # status for a resource that exists but is temporarily unavailable
        # due to lock state. We surface retry_after_seconds in BOTH the
        # standard Retry-After header (for HTTP-compliant clients) and in
        # the JSON body (for SPA UIs that need to render a countdown).
        emit_login_failure(:account_locked)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> put_status(423)
        |> json(%{error: "account_locked", retry_after_seconds: retry_after_seconds})

      {:error, :argon2_busy} ->
        emit_login_failure(:service_busy)

        conn
        |> put_status(503)
        |> put_resp_header("retry-after", "5")
        |> json(%{error: "service_busy"})
    end
  end

  def login(conn, _params) do
    emit_login_failure(:missing_params)

    conn
    |> put_status(422)
    |> json(%{error: "email and password are required"})
  end

  defp emit_login_failure(type)
       when type in [
              :invalid_credentials,
              :email_unconfirmed,
              :missing_params,
              :account_locked,
              :service_busy
            ] do
    :telemetry.execute([:stacks, :auth, :login_failure], %{count: 1}, %{type: type})
  end

  @doc "DELETE /api/auth/logout — revoke the current JWT."
  def logout(conn, _params) do
    token = Guardian.Plug.current_token(conn)
    claims = Guardian.Plug.current_claims(conn) || %{}

    # Revoke server-side (deletes the guardian_tokens row). We still return 204
    # even if revocation fails — the client should consider itself logged out —
    # but a failure means the token stays valid until its ttl expires, so it must
    # be logged for investigation rather than silently discarded.
    case Guardian.revoke(token) do
      {:ok, _claims} ->
        :ok

      error ->
        Logger.warning("Guardian.revoke failed on logout: #{inspect(error)}")
    end

    case claims do
      %{"family_id" => family_id} when is_binary(family_id) ->
        Accounts.revoke_token_family(family_id)

      _ ->
        :ok
    end

    send_resp(conn, 204, "")
  end

  @doc """
      POST /api/auth/forgot-password — enqueue a password reset email.

      ⛔ MIRROR, like `resend_confirmation/2`: sent, suppressed-by-the-limiter
      and no-such-account all get the same status, body and headers, or this
      unauthenticated endpoint becomes an account-existence oracle.

      `Email.send_password_reset/1` still reports which of those happened. The
      outcome is spent HERE — on a log line an operator can correlate to the
      request id when a reader says the link never arrived — and is never
      reflected into the response.
  """
  def forgot_password(conn, %{"email" => email}) do
    case Email.send_password_reset(email) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        Logger.warning(
          "password reset suppressed by the email rate limiter — the reader who " <>
            "asked was told a link was on its way and will not receive one"
        )
    end

    json(conn, %{message: "If that email exists, a reset link has been sent"})
  end

  def forgot_password(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "email is required"})
  end

  @doc """
      POST /api/auth/resend-confirmation — issue a fresh confirmation link.

      ⛔ This action must be a MIRROR: the reply may not depend on the email.
      Unconfirmed, already-confirmed, past-the-cap, and no-account addresses
      all get the same status, body and headers — any observable difference
      makes an unauthenticated endpoint an account-existence oracle over the
      whole user base. Guessing cost is carried by the shared `:auth` rate
      bucket.

      `Email.send_confirmation_resend/1` reports whether the link was actually
      issued. That answer is spent HERE — the mirror is enforced by this
      function returning the same reply for every branch, not by the context
      being kept ignorant of what it did.
  """
  def resend_confirmation(conn, %{"email" => email}) do
    case Email.send_confirmation_resend(email) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        Logger.warning(
          "confirmation resend suppressed by the email rate limiter — the reader " <>
            "who asked was told a link was on its way and will not receive one"
        )
    end

    json(conn, %{
      message: "If that address needs confirming, a fresh link is on its way"
    })
  end

  def resend_confirmation(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "email is required"})
  end

  @doc "POST /api/auth/reset-password — reset password using a signed token."
  def reset_password(conn, %{"token" => token, "password" => password}) do
    case Email.reset_password(token, password) do
      {:ok, _user} ->
        json(conn, %{message: "Password updated successfully"})

      {:error, :expired} ->
        conn
        |> put_status(400)
        |> json(%{error: "token_expired"})

      {:error, :invalid} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_token"})

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: errors})
    end
  end

  def reset_password(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "token and password are required"})
  end

  @doc """
      POST /api/auth/refresh — rotate the current JWT for a fresh one.

      Reachable only behind the `:authenticated` pipeline, so an expired, revoked,
      or absent token is rejected with 401 before this action runs. On a valid
      token we rotate: the old token is revoked server-side (its `guardian_tokens`
      row is deleted, so it can never be used again) and a fresh token with the
      standard 8h access TTL is minted. Response mirrors login's `%{token, user}`
      shape so the SPA can swap tokens transparently during silent renewal.
  """
  def refresh(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    old_token = Guardian.Plug.current_token(conn)
    now = System.system_time(:second)

    claims = Guardian.Plug.current_claims(conn) || %{}

    session_start =
      case claims do
        %{"sst" => sst} when is_integer(sst) -> sst
        _ -> now
      end

    family_id =
      case claims do
        %{"family_id" => fid} when is_binary(fid) -> fid
        _ -> Ecto.UUID.generate()
      end

    if now - session_start > session_cap_seconds() do
      revoke_refresh_token(old_token)

      :telemetry.execute([:stacks, :auth, :session, :expired], %{count: 1}, %{
        reason: :lifetime_cap
      })

      conn
      |> put_status(401)
      |> json(%{error: "session_expired"})
    else
      revoke_refresh_token(old_token)

      old_jti = claims["jti"]

      {:ok, token, new_claims} =
        Guardian.encode_and_sign(user, %{"sst" => session_start, "family_id" => family_id})

      Accounts.rotate_token_family(%{
        family_id: family_id,
        user_id: user.id,
        current_jti: new_claims["jti"],
        previous_jti: old_jti,
        rotated_at: DateTime.utc_now(),
        session_started_at: DateTime.from_unix!(session_start)
      })

      :telemetry.execute([:stacks, :auth, :jwt_issued], %{count: 1}, %{context: :refresh})

      json(conn, %{token: token, user: ProtoJSON.user(user)})
    end
  end

  # Revoke the presented token during a refresh (rotation). On failure the old
  # token stays valid until its TTL expires, weakening rotation, so the degraded
  # case is logged AND counted via telemetry so it is alertable.
  defp revoke_refresh_token(token) do
    case Guardian.revoke(token) do
      {:ok, _claims} ->
        :ok

      error ->
        Logger.warning("Guardian.revoke failed during refresh: #{inspect(error)}")
        :telemetry.execute([:stacks, :auth, :refresh, :revoke_failed], %{count: 1}, %{})
    end
  end

  defp session_cap_seconds do
    :core
    |> Application.get_env(:session_absolute_cap, {7, :day})
    |> Duration.to_seconds()
  end

  @doc "GET /api/auth/me — return the current authenticated user."
  def me(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    json(conn, %{user: ProtoJSON.user(user)})
  end

  defp get_ip(conn), do: StacksWeb.ClientIP.get(conn)

  defp invite_error_status(:invite_expired), do: 410
  defp invite_error_status(:invite_exhausted), do: 409
  defp invite_error_status(_), do: 403

  defp invite_telemetry_label(:invite_required), do: :required
  defp invite_telemetry_label(:invite_invalid), do: :invalid
  defp invite_telemetry_label(:invite_expired), do: :expired
  defp invite_telemetry_label(:invite_revoked), do: :revoked
  defp invite_telemetry_label(:invite_exhausted), do: :exhausted
  defp invite_telemetry_label(:invite_email_mismatch), do: :email_mismatch

  # A catch-all, because this function is reached from an UNAUTHENTICATED
  # registration path and its only job is to produce a metric label.
  #
  # Its sibling `invite_error_status/1` two clauses below is total — it ends in
  # `_ -> 403`. This one was not, and the asymmetry is the whole point.
  #
  # ⚠️ An earlier version of this comment justified the catch-all by naming
  # `:invite_not_found` as "one `with` clause away from reaching here". That was
  # plausible, unchecked and false: `:invite_not_found` is produced only by
  # `Invites.check/1` and consumed only by `InviteController`, which answers it
  # with a 404 — a different controller behind a different context function
  # whose declared return type does not include it. Recorded rather than quietly
  # rewritten, because the argument is the kind that would be re-derived from the
  # same wrong premise by the next person to consider deleting the clause.
  #
  # The real exposure is WIDER than that claim, which is why the catch-all earns
  # its place. `Accounts.do_register/3` ends in
  # `{:error, _, reason, _} -> {:error, reason}` — a pass-through over EVERY step
  # of the registration Multi, not just the invite steps. So the input set here
  # is "any atom any step of that Multi returns, present or future", not the
  # invite gate's six refusal atoms. `Accounts.register/2`'s `@spec` lists those
  # six and is therefore narrower than its own body; dialyzer will not flag a
  # spec narrower than the success typing without `--overspecs`, so that spec is
  # documentation rather than a guarantee, and it is exactly what a reader would
  # use to conclude this function's input set is closed. It is not.
  #
  # Without the catch-all, a future `Multi.run` step returning `{:error, :atom}`
  # raises `FunctionClauseError` here — a 500 on registration, which is both the
  # worst place for one and a distinguishable response on an endpoint designed
  # to tell a prober nothing. (No such step exists today: the only atom-returning
  # ones are the six invite steps, `:set_confirmation` fails with a changeset,
  # and `consume_invite/3` raises rather than returning a tuple.)
  #
  # `:other` keeps the label BOUNDED, which is what a Prometheus label has to be,
  # while still recording that a refusal happened. An unexpected atom showing up
  # as `other` in the metric is a signal to come and add a clause; a 500 is not.

  defp invite_telemetry_label(_unexpected), do: :other

  @doc """
      The invite-gate label mapping, exposed so its TOTALITY can be asserted.

      Its sibling status function is total and this one was not; the label guard
      declares this label bounded, and that declaration is only true while every
      input maps to something.
  """
  @spec invite_label_for(atom()) :: atom()
  def invite_label_for(reason), do: invite_telemetry_label(reason)
end
