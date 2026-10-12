defmodule StacksWeb.Plugs.ConsentCheck do
  @moduledoc """
      Plug that halts with 403 if the current user has not granted consent
      for the specified feature. Defaults to checking analytics consent.

      Usage:
        plug StacksWeb.Plugs.ConsentCheck, feature: "analytics"
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Stacks.GDPR.Consent

  def init(opts), do: opts

  def call(conn, opts) do
    # The "analytics" default is reserved, not live: no route uses it, and no
    # code path reads `consent_analytics`. Nothing is collected under it, so
    # the answer is recorded ahead of a feature that does not exist yet. The
    # settings page says so in as many words — keep the two in step.
    feature = Keyword.get(opts, :feature, "analytics")
    user = Guardian.Plug.current_resource(conn)

    if user && Consent.check_consent(user.id, feature) do
      conn
    else
      conn
      |> put_status(403)
      |> json(%{error: "consent_required", feature: feature})
      |> halt()
    end
  end
end
