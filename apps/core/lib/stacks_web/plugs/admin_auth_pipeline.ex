defmodule StacksWeb.Plugs.AdminAuthPipeline do
  @moduledoc """
      Plug that authenticates an operator and attaches their admin session.

      ⛔ ELEVATION IS A FACT ABOUT THE SESSION THE SERVER HOLDS, NOT A
      CREDENTIAL THE CLIENT CARRIES. This pipeline used to extract a second
      Guardian token (`typ: "admin_session"`) from the `Authorization` header
      and find the admin session by a `sid` claim inside it. The SPA held that
      token in memory and nothing persisted it, so **a reload dropped it and
      re-prompted for MFA** even though `SessionContext.mark_mfa_verified/1`
      had already recorded the elevation server-side. The operator was being
      asked to prove something the server already knew.

      So the chain starts from the ordinary session instead: the reader is
      identified exactly as on every other authenticated route — the HttpOnly
      cookie, through `SessionCookie` and Guardian — and the admin session is
      then looked up from that user.

      ⚖️ **What is a move and what is new.** Not-revoked, not-expired, matching
      `boot_id` and matching IP are unchanged; they live in
      `SessionContext.check_valid/2` and are shared with `get_valid/2` so the
      rules cannot drift. The only new part is *which* admin session —
      `current_for_user/2` answers "the most recent still-valid one", because an
      operator accumulates them over time.

      ⚠️ The MFA window is NOT checked here. `StacksWeb.Plugs.RequireMFA` owns
      it and is piped immediately after (`router.ex:97-99`), holding
      `@mfa_window_minutes` as the single expression of that window. Adding a
      second check here is how a window starts meaning two things.

      On success, assigns `:current_user` and `:admin_session`. On any failure,
      halts with a 401 JSON response.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.Accounts.Guardian
  alias Stacks.Admin.SessionContext

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    with {:ok, user} <- authenticated_user(conn),
         {:ok, session} <- SessionContext.current_for_user(user.id, client_ip(conn)) do
      conn
      |> assign(:current_user, user)
      |> assign(:admin_session, session)
    else
      _ -> unauthorized(conn)
    end
  end

  # ⚠️ Reads the resource the ordinary pipeline already loaded rather than
  # re-verifying a credential. These routes `pipe_through [:api, :admin, …]`,
  # and `:api` does not authenticate — so this asks Guardian for the resource
  # the session cookie established, which is the same question
  # `Guardian.Plug.current_resource/1` answers everywhere else.
  defp authenticated_user(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> {:error, :not_authenticated}
      user -> {:ok, user}
    end
  end

  # Via ClientIP, NOT bare remote_ip: behind Fly the peer is the proxy's own
  # address and varies between requests, so an MFA-verified session minted at
  # the password step answered :ip_mismatch on the very next request whenever
  # it traversed a different proxy — shown to the operator as a network error.
  defp client_ip(conn), do: StacksWeb.ClientIP.get(conn)

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
