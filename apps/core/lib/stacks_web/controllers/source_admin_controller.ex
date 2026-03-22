defmodule StacksWeb.SourceAdminController do
  @moduledoc """
  Admin controller for managing discovered sources.

  Only accessible to users with `role: "owner"`. The role check is enforced
  by the `RequireRole` plug in the router pipeline.
  """

  use CoreWeb, :controller

  action_fallback CoreWeb.FallbackController

  alias Stacks.Discovery
  alias Stacks.Enrichment.DiscoveredSource

  def index(conn, params) do
    opts = [
      status: params["status"],
      type: params["type"],
      page: params["page"] || "1",
      per_page: params["per_page"] || "50"
    ]

    {sources, total} = Discovery.list_sources(opts)

    json(conn, %{
      sources: Enum.map(sources, &serialize_source/1),
      total: total,
      page: parse_page(opts[:page])
    })
  end

  def approve(conn, %{"id" => id}) do
    with {:ok, source} <- Discovery.approve_source(id) do
      json(conn, %{source: serialize_source(source)})
    end
  end

  def reject(conn, %{"id" => id}) do
    with {:ok, source} <- Discovery.reject_source(id) do
      json(conn, %{source: serialize_source(source)})
    end
  end

  defp serialize_source(%DiscoveredSource{} = s) do
    %{
      id: s.id,
      name: s.name,
      type: s.type,
      url: s.url,
      confidence: s.confidence,
      discovered_via: s.discovered_via,
      discovered_at: s.discovered_at,
      status: s.status,
      approved_at: s.approved_at,
      created_at: s.created_at
    }
  end

  defp parse_page(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(n, 1)
      :error -> 1
    end
  end

  defp parse_page(_), do: 1
end
