defmodule StacksWeb.SourceAdminController do
  @moduledoc """
  Admin controller for managing discovered sources.

  Requires an MFA-verified admin session JWT. Role is enforced at JWT issuance
  by `AdminAuthController.login/2` — not repeated per action.
  """

  use CoreWeb, :controller

  action_fallback CoreWeb.FallbackController

  alias Stacks.Discovery
  alias Stacks.Enrichment.DiscoveredSource
  alias Stacks.Monitoring

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

  @doc """
  GET /api/admin/removal-requests — businesses waiting on a human decision.

  A removal request whose contact address did not match the listing's domain parks with
  `exclusion_requested_at` set. This is where those become visible; before it, they were
  not in any payload at all.
  """
  def removal_requests(conn, _params) do
    requests =
      Discovery.pending_removal_requests()
      |> Enum.map(&serialize_removal_request/1)

    json(conn, %{requests: requests, total: length(requests)})
  end

  @doc """
  PUT /api/admin/removal-requests/:id/honour — remove the listing.

  ⚠️ **Not `approve`.** `PUT /sources/:id/approve` already exists and *publishes* a
  listing; this takes one down. Two endpoints named "approve" with opposite effects on the
  same row is a mistake waiting to happen, so these name what happens to the listing.
  """
  def honour_removal(conn, %{"id" => id}) do
    case Discovery.honour_removal_request(id) do
      {:ok, _source} -> json(conn, %{ok: true, outcome: "removed"})
      {:error, reason} -> removal_error(conn, reason)
    end
  end

  @doc "PUT /api/admin/removal-requests/:id/decline — the listing stays."
  def decline_removal(conn, %{"id" => id}) do
    case Discovery.decline_removal_request(id) do
      {:ok, _source} -> json(conn, %{ok: true, outcome: "kept"})
      {:error, reason} -> removal_error(conn, reason)
    end
  end

  defp removal_error(conn, :not_found) do
    conn |> put_status(404) |> json(%{error: "No such removal request."})
  end

  defp removal_error(conn, :not_pending) do
    conn |> put_status(409) |> json(%{error: "That request has already been decided."})
  end

  defp removal_error(conn, _reason) do
    conn |> put_status(422) |> json(%{error: "Could not record that decision."})
  end

  defp serialize_removal_request(%DiscoveredSource{} = s) do
    %{
      id: s.id,
      name: s.name,
      url: s.url,
      type: s.type,
      exclusion_email: s.exclusion_email,
      requested_at: s.exclusion_requested_at,
      status: s.status
    }
  end

  @doc "GET /api/admin/source-health — per-source health for the scraper-health page."
  def source_health(conn, _params) do
    json(conn, %{data: Monitoring.list_source_health()})
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
