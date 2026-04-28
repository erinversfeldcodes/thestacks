defmodule StacksWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Sets security-related HTTP response headers on every request.
  Headers follow OWASP recommendations and the project security standards doc.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("permissions-policy", "camera=(), microphone=(), geolocation=()")
    # connect-src whitelists R2 because the presigned-URL upload flow PUTs
    # file bytes directly from the browser to
    # <account>.r2.cloudflarestorage.com. Without this, the browser blocks
    # the PUT and uploads fail silently.
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; " <>
        "script-src 'self'; " <>
        "style-src 'self' 'unsafe-inline'; " <>
        "img-src 'self' https://covers.openlibrary.org https://books.google.com data:; " <>
        "connect-src 'self' https://*.r2.cloudflarestorage.com; " <>
        "font-src 'self'; " <>
        "frame-ancestors 'none'"
    )
    |> put_resp_header(
      "strict-transport-security",
      "max-age=63072000; includeSubDomains; preload"
    )
    |> put_resp_header("cache-control", "no-store")
  end
end
