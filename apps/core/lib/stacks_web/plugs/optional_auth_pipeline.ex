defmodule StacksWeb.Plugs.OptionalAuthPipeline do
  @moduledoc """
      Optional Guardian JWT authentication pipeline.

      Verifies Bearer tokens in the Authorization header when present,
      but does not require authentication. Unauthenticated requests
      proceed with `Guardian.Plug.current_resource/1` returning `nil`.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :core,
    error_handler: StacksWeb.Plugs.AuthErrorHandler,
    module: Stacks.Accounts.Guardian

  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.LoadResource, allow_blank: true
end
