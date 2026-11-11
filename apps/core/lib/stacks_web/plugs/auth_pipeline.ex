defmodule StacksWeb.Plugs.AuthPipeline do
  @moduledoc """
      Guardian JWT authentication pipeline.

      Verifies a session carried by cookie OR by Bearer token in the
      Authorization header. On failure, delegates to
      `StacksWeb.Plugs.AuthErrorHandler` which returns JSON 401/403 responses.

      ⛔ BOTH TRANSPORTS, FOR ONE RELEASE, AND THE ORDER DECIDES PRECEDENCE.
      `SessionCookie` runs first and puts the cookie's token on the conn;
      `VerifyHeader` then no-ops, because its `call/2` returns early when a
      token is already present. So the cookie wins when present and the header
      is found when it is not, with no branch in either plug.

      ⚠️ PROBED, and narrower than the obvious claim: reversing the two reds
      exactly ONE test. The cookie-only path survives a reversal, because
      `VerifyHeader` with no header does not refuse — it falls through. What
      reversing actually breaks is the PRECEDENCE when a client sends both, and
      with it the transport counter's reading in the mixed case. That is the
      case the rollout turns on, since a mid-migration client is exactly the one
      sending both.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :core,
    error_handler: StacksWeb.Plugs.AuthErrorHandler,
    module: Stacks.Accounts.Guardian

  plug StacksWeb.Plugs.SessionCookie
  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource, allow_blank: false
  plug StacksWeb.Plugs.RequireConfirmedEmail
end
