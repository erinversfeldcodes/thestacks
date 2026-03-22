defmodule StacksWeb.AuthController do
  @moduledoc """
  Handles authentication endpoints: register, login, logout, and current user.
  """

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Audit
  alias Stacks.Email

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

        json(conn, %{token: token, user: format_user(user)})

      {:error, :email_unconfirmed} ->
        conn
        |> put_status(403)
        |> json(%{error: "email_unconfirmed"})

      {:error, :invalid_credentials} ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid_credentials"})
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
    Guardian.revoke(token)

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
    json(conn, %{user: format_user(user)})
  end

  defp format_user(user) do
    %{
      id: user.id,
      email: user.email,
      display_name: user.display_name,
      role: user.role,
      profile_visibility: user.profile_visibility,
      age_verified: user.age_verified,
      consent_analytics: user.consent_analytics
    }
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
