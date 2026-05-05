defmodule StacksWeb.PartnerController do
  @moduledoc "Platform-owner endpoints for managing partner applications."

  use CoreWeb, :controller

  alias Stacks.Partners
  alias StacksWeb.ProtoJSON

  action_fallback CoreWeb.FallbackController

  def index(conn, _params) do
    partners = Partners.list_pending_partners()
    json(conn, %{partners: Enum.map(partners, &ProtoJSON.partner/1)})
  end

  def approve(conn, %{"id" => partner_id}) do
    user = conn.assigns.current_user

    case Partners.approve_partner(partner_id, user.id) do
      {:ok, {_partner, raw_key}} ->
        json(conn, %{data: %{api_key: raw_key, message: "Key shown once — store it securely."}})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :already_approved} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "already_approved"})
    end
  end

  def reject(conn, %{"id" => partner_id}) do
    user = conn.assigns.current_user
    reason = Map.get(conn.body_params, "reason")

    case Partners.reject_partner(partner_id, user.id, reason) do
      {:ok, _partner} ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end
end
