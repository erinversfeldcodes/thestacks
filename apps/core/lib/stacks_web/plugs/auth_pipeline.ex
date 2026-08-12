defmodule StacksWeb.Plugs.AuthPipeline do
  @moduledoc """
      Guardian JWT authentication pipeline.

      Verifies Bearer tokens in the Authorization header. On failure, delegates
      to `StacksWeb.Plugs.AuthErrorHandler` which returns JSON 401/403 responses.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :core,
    error_handler: StacksWeb.Plugs.AuthErrorHandler,
    module: Stacks.Accounts.Guardian

  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource, allow_blank: false
  plug StacksWeb.Plugs.RequireConfirmedEmail
end
