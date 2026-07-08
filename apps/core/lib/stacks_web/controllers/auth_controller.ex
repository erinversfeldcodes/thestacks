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

        conn
        |> put_status(201)
        |> json(%{message: "confirmation_email_sent"})

      {:error, changeset} ->
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

        {:ok, token, _claims} = Guardian.encode_and_sign(user)

        json(conn, %{token: token, user: ProtoJSON.user(user)})

      {:error, :email_unconfirmed} ->
        conn
        |> put_status(403)
        |> json(%{error: "email_unconfirmed"})

      {:error, :invalid_credentials} ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid_credentials"})

      {:error, {:account_locked, retry_after_seconds}} ->
        # Per-account login lockout (Issue #161). 423 Locked is the standard
        # status for a resource that exists but is temporarily unavailable
        # due to lock state. We surface retry_after_seconds in BOTH the
        # standard Retry-After header (for HTTP-compliant clients) and in
        # the JSON body (for SPA UIs that need to render a countdown).
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> put_status(423)
        |> json(%{error: "account_locked", retry_after_seconds: retry_after_seconds})

      {:error, :argon2_busy} ->
        conn
        |> put_status(503)
        |> put_resp_header("retry-after", "5")
        |> json(%{error: "service_busy"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "email and password are required"})
  end

  @doc "DELETE /api/auth/logout — revoke the current JWT."
  def logout(conn, _params) do
    token = Guardian.Plug.current_token(conn)

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

  @doc "GET /api/auth/me — return the current authenticated user."
  def me(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    json(conn, %{user: ProtoJSON.user(user)})
  end

  defp get_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        # x-forwarded-for may be comma-separated when multiple proxies are in the chain.
        # Take the leftmost IP (the original client) and strip any whitespace.
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
