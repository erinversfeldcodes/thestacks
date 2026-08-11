defmodule StacksWeb.ConfigController do
  @moduledoc """
    Public runtime configuration for the frontend (ADR-020).

    The SPA has no other way to learn which server-side feature flags are active,
    so `GET /api/config` exposes the small, non-sensitive subset it needs to render
    correctly — currently just whether age-gating is enabled. Unauthenticated and
    safe to cache-bust freely: it contains only boolean flags, never user or
    partner data.

    Keep the payload a flat map so future flags can be added without a new route.
  """

  use CoreWeb, :controller

  @doc """
    GET /api/config — returns the frontend-visible feature-flag map.

    Response: `{"ageGatingEnabled": <boolean>, "inviteOnly": <boolean>}` — the
    flat-map contract ADR-020 established, one boolean per flag.
  """
  def show(conn, _params) do
    json(conn, %{
      ageGatingEnabled: Stacks.FeatureFlags.age_gating_enabled?(),
      inviteOnly: Stacks.FeatureFlags.invite_only_registration?()
    })
  end
end
