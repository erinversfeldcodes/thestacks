defmodule StacksWeb.TransparencyController do
  @moduledoc """
    Public, unauthenticated controller for the curated transparency metrics.

    `GET /api/transparency/metrics` returns `{live, durable, generated_at,
    cache_ttl}` — a allowlisted, anonymised subset of platform observability with
    teaching metadata per entry. It never proxies the raw `/internal/metrics`
    firehose, never accepts a user-supplied PromQL query, and exposes no PII or
    de-anonymisable dimension. See `Stacks.Transparency` for the privacy boundary.
  """

  use CoreWeb, :controller

  alias Stacks.Transparency

  @doc "GET /api/transparency/metrics — the public transparency payload."
  def index(conn, _params) do
    json(conn, Transparency.metrics())
  end
end
