defmodule StacksWeb.AdminAuthController do
  @moduledoc """
    Controller for break-glass admin authentication.

    Provides endpoints for:
    - `login/2` — authenticate with email/password, returns session_id
    - `verify_mfa/2` — verify TOTP or recovery code, returns admin JWT
    - `logout/2` — revoke the current admin session
    - `mfa_setup/2` — begin MFA enrollment (returns provisioning URI + codes)
    - `mfa_confirm/2` — confirm MFA enrollment with a TOTP code
  """

  use CoreWeb, :controller

  alias Core.Repo
  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext
  alias Stacks.AdminSession
  alias Stacks.Audit
  alias Stacks.MFA

  @doc "POST /api/admin/auth/login"
  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, %{"email" => email, "password" => password}) do
    with {:ok, user} <- authenticate(email, password),
         :ok <- check_owner_role(user),
         :ok <- check_mfa_enrolled(user) do
      boot_id = Core.Application.boot_id()
      raw_ip = get_raw_ip(conn)
      {:ok, session} = SessionContext.create(user, raw_ip, boot_id)

      Audit.log(user.id, "admin.login",
        resource_type: "admin_session",
        operator_session_id: session.id
      )

      json(conn, %{session_id: session.id})
    else
      {:error, :invalid_credentials} ->
        conn |> put_status(401) |> json(%{error: "invalid_credentials"})

      {:error, :email_unconfirmed} ->
        conn |> put_status(403) |> json(%{error: "email_unconfirmed"})

      {:error, :insufficient_role} ->
        conn |> put_status(403) |> json(%{error: "insufficient_role"})

      {:error, :mfa_not_enrolled} ->
        conn |> put_status(403) |> json(%{error: "mfa_not_enrolled"})
    end
  end

  @doc "POST /api/admin/auth/verify_mfa"
  @spec verify_mfa(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify_mfa(conn, params) do
    session_id = params["session_id"]

    with {:ok, session} <- load_session_for_verify(session_id),
         :pending <- mfa_status(session),
         {:ok, user} <- load_session_user(session),
         :ok <- verify_mfa_code(user, params) do
      {:ok, session} = SessionContext.mark_mfa_verified(session)

      Audit.log(user.id, "admin.mfa_verified",
        resource_type: "admin_session",
        operator_session_id: session.id
      )

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, %{},
          token_type: "admin",
          session_id: session.id,
          boot_id: Core.Application.boot_id(),
          ttl: {30, :minute}
        )

      json(conn, %{token: token})
    else
      :already_verified ->
        conn |> put_status(409) |> json(%{error: "already_verified"})

      {:error, :invalid_session} ->
        conn |> put_status(401) |> json(%{error: "invalid_session"})

      {:error, :invalid_code} ->
        conn |> put_status(401) |> json(%{error: "invalid_code"})

      _ ->
        conn |> put_status(401) |> json(%{error: "invalid_session"})
    end
  end

  @doc "DELETE /api/admin/auth/logout"
  @spec logout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def logout(conn, _params) do
    session = conn.assigns[:admin_session]
    {:ok, _} = SessionContext.revoke(session)
    json(conn, %{ok: true})
  end

  @doc "POST /api/admin/auth/mfa/setup"
  @spec mfa_setup(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mfa_setup(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    {:ok, %{provisioning_uri: uri, recovery_codes: codes}} = MFA.begin_enrollment(user)
    json(conn, %{provisioning_uri: uri, recovery_codes: codes})
  end

  @doc "POST /api/admin/auth/mfa/confirm"
  @spec mfa_confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mfa_confirm(conn, %{"totp_code" => totp_code, "secret" => encoded_secret} = params) do
    user = Guardian.Plug.current_resource(conn)
    recovery_codes = Map.get(params, "recovery_codes", [])

    case Base.decode32(encoded_secret, padding: false) do
      {:ok, secret} ->
        case MFA.confirm_enrollment(user, totp_code, secret, recovery_codes) do
          {:ok, _mfa} ->
            json(conn, %{ok: true})

          {:error, :invalid_code} ->
            conn |> put_status(422) |> json(%{error: "invalid_code"})
        end

      :error ->
        conn |> put_status(422) |> json(%{error: "invalid_secret"})
    end
  end

  defp authenticate(email, password) do
    case Accounts.authenticate(email, password) do
      {:ok, user} -> {:ok, user}
      {:error, :invalid_credentials} -> {:error, :invalid_credentials}
      {:error, :email_unconfirmed} -> {:error, :email_unconfirmed}
      {:error, _} -> {:error, :invalid_credentials}
    end
  end

  defp check_owner_role(%{role: "owner"}), do: :ok
  defp check_owner_role(_), do: {:error, :insufficient_role}

  defp check_mfa_enrolled(user) do
    if MFA.mfa_enabled?(user) do
      :ok
    else
      {:error, :mfa_not_enrolled}
    end
  end

  defp mfa_status(%AdminSession{mfa_verified_at: nil}), do: :pending
  defp mfa_status(%AdminSession{}), do: :already_verified

  defp load_session_user(session) do
    case Accounts.get_user(session.user_id) do
      nil -> {:error, :invalid_session}
      user -> {:ok, user}
    end
  end

  defp load_session_for_verify(nil), do: {:error, :invalid_session}

  defp load_session_for_verify(session_id) do
    case Repo.get(AdminSession, session_id, prefix: "op") do
      nil ->
        {:error, :invalid_session}

      session ->
        cond do
          session.revoked_at != nil ->
            {:error, :invalid_session}

          DateTime.compare(session.expires_at, DateTime.utc_now()) == :lt ->
            {:error, :invalid_session}

          session.boot_id != Core.Application.boot_id() ->
            {:error, :invalid_session}

          true ->
            {:ok, session}
        end
    end
  end

  defp verify_mfa_code(user, %{"totp_code" => code}), do: MFA.verify_totp(user, code)
  defp verify_mfa_code(user, %{"recovery_code" => code}), do: MFA.verify_recovery_code(user, code)
  defp verify_mfa_code(_user, _params), do: {:error, :invalid_code}

  defp get_raw_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
