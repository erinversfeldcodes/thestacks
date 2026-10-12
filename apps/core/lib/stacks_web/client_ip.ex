defmodule StacksWeb.ClientIP do
  @moduledoc """
      The one way this app answers "what is the caller's IP address?".

      Behind Fly's proxy, `conn.remote_ip` is the PROXY's internal peer address
      — different requests can traverse different proxy instances, so it is
      neither the client nor even stable. `fly-client-ip` is set by Fly's edge
      authoritatively (a client-supplied copy is overwritten before the request
      reaches the app), so it is the trusted-proxy answer. Locally there is no
      proxy, no header, and the TCP peer IS the client — the fallback.

      ⛔ `x-forwarded-for` is never read, anywhere. It is client-appendable and
      trusting it is how spoofed provenance gets into audit rows —
      `audit_ip_deployed_test.exs` pins that a spoofed XFF is NOT recorded.

      Three sites derived this independently before this module existed — the
      rate limiter and the auth controller correctly, and the admin session
      pipeline from bare `remote_ip`, which pinned MFA-verified admin sessions
      to whichever proxy instance carried the password step. The next request
      through a different proxy answered `:ip_mismatch`, surfaced to the
      operator as "Could not reach the server." One helper, so a fourth site
      cannot get it wrong again.
  """

  @doc "The client IP as a string. See the moduledoc for trust reasoning."
  @spec get(Plug.Conn.t()) :: String.t()
  def get(conn), do: conn |> get_with_source() |> elem(0)

  @doc """
      The client IP plus where it came from — `:trusted_proxy` for the
      Fly-set header, `:remote_ip` for the raw peer. The rate limiter counts
      the source so a header regression is visible in telemetry.
  """
  @spec get_with_source(Plug.Conn.t()) :: {String.t(), :trusted_proxy | :remote_ip}
  def get_with_source(conn) do
    case Plug.Conn.get_req_header(conn, "fly-client-ip") do
      [ip | _] when ip != "" ->
        {ip, :trusted_proxy}

      _ ->
        {conn.remote_ip |> :inet.ntoa() |> to_string(), :remote_ip}
    end
  end
end
