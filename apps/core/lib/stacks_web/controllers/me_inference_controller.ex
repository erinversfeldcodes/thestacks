defmodule StacksWeb.MeInferenceController do
  @moduledoc """
      GET /api/me/inferences — the authed, own-only personal inference &
      de-anonymisation education view.

      Strictly own-only: the payload is derived from the current user's own records
      only. There is no user/path/query parameter that selects another user — the
      resource is always `Guardian.Plug.current_resource/1`. The `:authenticated`
      pipeline returns 401 for unauthenticated requests.

      The sensitive `risk_inferences` section is included only when the request
      carries `?reveal_risk=true`, so the "show me what could be inferred"
      action is enforced server-side rather than by the client choosing not to
      render it.

      ⚠️ **That is a deliberate-request gate, NOT `ConsentCheck`.** This
      docstring used to call it "consent-gated", which reads as a consent record
      being checked — `Stacks.GDPR.Consent` is feature-parameterised and
      `risk_inferences` is not one of its features. Nothing is wrong with the
      behaviour: this is the subject's own data, shown to them, only when they
      ask. But a reader who believed a consent record stood behind it would be
      wrong, and would build the next sensitive section on a gate that does not
      exist.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Insights

  @doc "GET /api/me/inferences — own-only personal inferences for the current user."
  def index(conn, params) do
    user = Guardian.Plug.current_resource(conn)
    reveal_risk? = params["reveal_risk"] == "true"

    payload = Insights.personal_inferences(user, reveal_risk: reveal_risk?)

    json(conn, payload)
  end
end
