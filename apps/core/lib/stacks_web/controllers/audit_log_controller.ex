defmodule StacksWeb.AuditLogController do
  @moduledoc """
    Read-only GDPR audit-log surface.

    Returns the authenticated user's own audit-log entries, paginated, with
    `metadata` decrypted for display. Hashed IP addresses are never selected or
    surfaced. This controller has no write/update/delete path — the underlying
    `audit.audit_log` table stays append-only.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Audit

  @doc """
    GET /api/settings/audit-log — the current user's audit history.

    Query parameters:
      * `page` — 1-based page number (default 1)
      * `per_page` — items per page (default 25, max 100)
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    {entries, total, page, per_page} =
      Audit.list_for_user(user.id,
        page: parse_int(params["page"], 1),
        per_page: parse_int(params["per_page"], 25)
      )

    json(conn, %{
      entries: Enum.map(entries, &render_entry/1),
      total: total,
      page: page,
      per_page: per_page
    })
  end

  defp render_entry(entry) do
    %{
      id: entry.id,
      action: entry.action,
      resource_type: entry.resource_type,
      resource_id: entry.resource_id,
      occurred_at: entry.occurred_at,
      metadata: entry.metadata
    }
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default
end
