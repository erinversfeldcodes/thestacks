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

        # Registration outcome counter (Issue #206 / auth §12). `result` is a
        # bounded label (:ok | :error) — never derived from user input — so the
        # `stacks_auth_registration_count_total{result=…}` series stays
        # low-cardinality and alertable for a registration-failure spike.
        :telemetry.execute([:stacks, :auth, :registration], %{count: 1}, %{result: :ok})

        conn
        |> put_status(201)
        |> json(%{message: "confirmation_email_sent"})

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

        # Open a refresh-token family (Issue #179, Phase 2a). Generate the
        # family_id BEFORE minting so the same value is embedded as a claim and
        # carried forward across every future rotation. `sst` is auto-stamped by
        # build_claims; we read it back to anchor session_started_at to the
        # session's true origin.
        fid = Ecto.UUID.generate()
        {:ok, token, claims} = Guardian.encode_and_sign(user, %{"family_id" => fid})

        family_attrs = %{
          family_id: fid,
          user_id: user.id,
          current_jti: claims["jti"],
          session_started_at: DateTime.from_unix!(claims["sst"])
        }

        case Accounts.open_token_family(family_attrs) do
          {:ok, _family} ->
            # JWT issuance counter (Issue #206 / auth §12). Counted only once the
            # token is actually handed to the client (family persisted); the
            # fail-closed branch below revokes an un-issued token and must NOT
            # count. `context` is a bounded label (:login | :refresh).
            :telemetry.execute([:stacks, :auth, :jwt_issued], %{count: 1}, %{context: :login})

            json(conn, %{token: token, user: ProtoJSON.user(user)})

          {:error, reason} ->
            # Fail closed: the token was minted (and a guardian_tokens row
            # written) but its family did not persist. Handing it out would
            # break the "every live token has a family" invariant that Phase 2b
            # relies on, so revoke the just-minted token and refuse the login.
            Logger.error("open_token_family failed on login: #{inspect(reason)}")
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
        # Per-account login lockout (Issue #161). 423 Locked is the standard
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

  # Login-failure-by-type counter (Issue #206 / auth §12). `type` is a bounded,
  # whitelisted atom drawn from the fixed set of login-error branches
  # (never raw user input), so `stacks_auth_login_failure_count_total{type=…}`
  # stays low-cardinality and gives operators a per-reason breakdown
  # (401 invalid_credentials, 403 email_unconfirmed, 422 missing_params,
  # 423 account_locked, 503 service_busy). 429 rate-limit rejections are
  # counted upstream in StacksWeb.Plugs.RateLimiter (the request never reaches
  # this action once the :auth bucket trips).
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

    # Revoke the whole family (Issue #179, Phase 2b): mark the family revoked so
    # any OTHER token sharing this session's family_id — e.g. an attacker's
    # stolen, already-rotated chain — dies at the verify_claims gate on its next
    # use, not just the single token we hold here. Scoped to this family (not a
    # by-sub burn) so logging out of one session does not kill the user's others.
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
  Always returns 200 regardless of whether the email is registered.
  """
  def forgot_password(conn, %{"email" => email}) do
    Email.send_password_reset(email)

    json(conn, %{message: "If that email exists, a reset link has been sent"})
  end

  def forgot_password(conn, _params) do
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

    # Absolute session-lifetime cap (Issue #179, Phase 1). Read the "sst"
    # (session-start) anchor stamped at login and carried forward across every
    # prior rotation. Missing/legacy `sst` policy: tokens minted before this
    # change (or the direct-action code path in tests) carry no anchor. Rather
    # than treat "unknown start" as infinitely old and lock those users out, we
    # stamp the anchor forward to `now` so a legacy session becomes bounded from
    # this moment — bounded, not immediately expired.
    claims = Guardian.Plug.current_claims(conn) || %{}

    session_start =
      case claims do
        %{"sst" => sst} when is_integer(sst) -> sst
        _ -> now
      end

    # Carry the refresh-token family forward across rotation (Issue #179,
    # Phase 2a). A legacy token minted before families existed carries no
    # family_id; rather than lock it out we adopt it into a new family from now
    # (lazy-create in rotate_token_family), mirroring the missing-sst policy.
    family_id =
      case claims do
        %{"family_id" => fid} when is_binary(fid) -> fid
        _ -> Ecto.UUID.generate()
      end

    if now - session_start > session_cap_seconds() do
      # Past the cap: the session may not be renewed beyond the window measured
      # from its ORIGINAL issue, no matter how many times it has rotated. Revoke
      # the presented token and refuse to mint — the #173 frontend interceptor
      # sends the user to /login on this 401.
      revoke_refresh_token(old_token)

      # Absolute session-lifetime-cap expiry (Issue #237). The session exceeded
      # its 7-day window measured from ORIGINAL issue and may not be renewed —
      # the user is force-logged-out. Count it so re-login spikes are visible.
      # `reason` is a bounded whitelisted atom (:lifetime_cap), NOT PII — no
      # token/user-id/IP in the metadata (telemetry is warehouse-adjacent, GDPR).
      :telemetry.execute([:stacks, :auth, :session, :expired], %{count: 1}, %{
        reason: :lifetime_cap
      })

      conn
      |> put_status(401)
      |> json(%{error: "session_expired"})
    else
      # Within the cap: rotate. Revoke the old token first so it stops working
      # immediately, then mint a fresh one CARRYING THE ANCHOR FORWARD so the
      # cap does not reset on renewal (survives rotation).
      revoke_refresh_token(old_token)

      # The jti being superseded — the OLD current token — becomes the family's
      # `previous_jti` so the reuse gate can honour it for a short grace window
      # (Issue #180). A legacy token with no jti claim yields nil (no grace).
      old_jti = claims["jti"]

      {:ok, token, new_claims} =
        Guardian.encode_and_sign(user, %{"sst" => session_start, "family_id" => family_id})

      # Advance the family's live token to the newly minted jti (lazy-creates the
      # row for a legacy/untracked session — see rotate_token_family). Record the
      # predecessor jti + rotation time atomically so the grace window applies to
      # the just-rotated old token only (Issue #180).
      Accounts.rotate_token_family(%{
        family_id: family_id,
        user_id: user.id,
        current_jti: new_claims["jti"],
        previous_jti: old_jti,
        rotated_at: DateTime.utc_now(),
        session_started_at: DateTime.from_unix!(session_start)
      })

      # JWT issuance counter (Issue #206 / auth §12) — a rotation mints a fresh
      # access token, so it is a real issuance. Tagged `context: :refresh` to
      # distinguish silent-renewal issuance from interactive login issuance.
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

  # Absolute session cap expressed as `{n, unit}` in config, converted to
  # seconds (NOT milliseconds) here at the check site.
  defp session_cap_seconds do
    {n, unit} = Application.get_env(:core, :session_absolute_cap, {7, :day})
    n * unit_in_seconds(unit)
  end

  defp unit_in_seconds(:second), do: 1
  defp unit_in_seconds(:minute), do: 60
  defp unit_in_seconds(:hour), do: 3_600
  defp unit_in_seconds(:day), do: 86_400
  defp unit_in_seconds(:week), do: 604_800

  @doc "GET /api/auth/me — return the current authenticated user."
  def me(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    json(conn, %{user: ProtoJSON.user(user)})
  end

  # Provenance IP for audit-log events. Key on the *trusted* client IP: Fly
  # sets and overwrites the `fly-client-ip` header at the edge with the real
  # client address, so it cannot be spoofed. `x-forwarded-for` is deliberately
  # NOT consulted — behind Fly its leftmost hop is client-supplied and trivially
  # forged, which would let an attacker poison the recorded provenance IP (Issue
  # #176, mirroring the RateLimiter fix). When the header is absent or empty
  # (local dev / ExUnit conns) we fall back to `conn.remote_ip`.
  defp get_ip(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [ip | _] when ip != "" -> ip
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
