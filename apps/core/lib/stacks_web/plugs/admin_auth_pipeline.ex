defmodule StacksWeb.Plugs.AdminAuthPipeline do
  @moduledoc """
      Plug that authenticates and validates admin sessions.

      Extracts a Bearer token from the Authorization header, verifies it as an
      admin token (`typ: "admin_session"`), validates the associated admin session
      (not revoked, not expired, matching boot_id and IP), and loads the user.

      On success, assigns `:current_user` and `:admin_session` to the conn.
      On any failure, halts with a 401 JSON response.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, claims} <- Guardian.decode_and_verify(token),
         :ok <- check_admin_type(claims),
         {:ok, session} <- SessionContext.get_valid(claims["sid"], get_raw_ip(conn)),
         {:ok, user} <- load_user(claims["sub"]) do
      conn
      |> assign(:current_user, user)
      |> assign(:admin_session, session)
    else
      _ -> unauthorized(conn)
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, token}
      _ -> {:error, :no_token}
    end
  end

  defp check_admin_type(%{"typ" => "admin_session"}), do: :ok
  defp check_admin_type(_), do: {:error, :not_admin_token}

  defp load_user(sub) do
    case Accounts.get_user(sub) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp get_raw_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
