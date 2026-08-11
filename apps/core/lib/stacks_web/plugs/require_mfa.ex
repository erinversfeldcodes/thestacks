defmodule StacksWeb.Plugs.RequireMFA do
  @moduledoc """
    Plug that enforces MFA verification on admin sessions.

    Reads `conn.assigns.admin_session` and checks that `mfa_verified_at` is set
    and within the last 30 minutes. If MFA is not verified or the verification
    has expired, halts with a 403 JSON response.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @mfa_window_minutes 30

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    session = conn.assigns[:admin_session]

    if mfa_valid?(session) do
      conn
    else
      conn
      |> put_status(403)
      |> json(%{error: "mfa_required"})
      |> halt()
    end
  end

  defp mfa_valid?(nil), do: false

  defp mfa_valid?(session) do
    case session.mfa_verified_at do
      nil ->
        false

      verified_at ->
        cutoff = DateTime.add(DateTime.utc_now(), -@mfa_window_minutes, :minute)
        DateTime.compare(verified_at, cutoff) == :gt
    end
  end
end
