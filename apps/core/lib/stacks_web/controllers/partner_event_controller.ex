defmodule StacksWeb.PartnerEventController do
  @moduledoc "Partner event management endpoints."

  use CoreWeb, :controller

  alias Stacks.Partners

  @doc "POST /api/partner/events — create a new event."
  def create(conn, params) do
    partner = conn.assigns[:current_partner]

    case Partners.create_partner_event(partner, params) do
      {:ok, event} ->
        conn
        |> put_status(:created)
        |> json(%{
          event: %{
            id: event.id,
            title: event.title,
            description: event.description,
            starts_at: event.event_date && DateTime.to_iso8601(event.event_date),
            ends_at: event.ends_at && DateTime.to_iso8601(event.ends_at),
            space_id: event.space_id
          }
        })

      {:error, :no_third_space} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Partner has no linked third space"})

      {:error, :starts_in_past} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "starts_at must be in the future"})

      {:error, :ends_before_starts} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "ends_at must be after starts_at"})

      {:error, :invalid_datetime} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid datetime format — use ISO8601"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  @doc "GET /api/partner/events — list partner's own events."
  def index(conn, _params) do
    partner = conn.assigns[:current_partner]
    events = Partners.list_partner_events(partner)

    json(conn, %{
      events:
        Enum.map(events, fn e ->
          %{
            id: e.id,
            title: e.title,
            description: e.description,
            starts_at: e.event_date && DateTime.to_iso8601(e.event_date),
            ends_at: e.ends_at && DateTime.to_iso8601(e.ends_at),
            space_id: e.space_id
          }
        end)
    })
  end

  @doc "DELETE /api/partner/events/:id — delete a partner's own event."
  def delete(conn, %{"id" => event_id}) do
    partner = conn.assigns[:current_partner]

    case Partners.delete_partner_event(partner, event_id) do
      {:ok, _event} ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :no_third_space} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Partner has no linked third space"})
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &interpolate_error/1)
  end

  defp interpolate_error({msg, opts}) do
    opts_map = Enum.into(opts, %{}, fn {k, v} -> {Atom.to_string(k), v} end)
    Regex.replace(~r"%{(\w+)}", msg, fn _, key -> to_string(Map.get(opts_map, key, key)) end)
  end
end
