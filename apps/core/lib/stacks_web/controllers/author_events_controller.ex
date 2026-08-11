defmodule StacksWeb.AuthorEventsController do
  @moduledoc """
  Public read for an author's bookstore events (#321 item 4: "surface
  events" — the book-detail author card's "Events coming soon" placeholder
  finally has something to say).

  Public because the data is: these are events scraped from bookshops' own
  public pages, carrying nothing about any reader. Dateless events are listed
  last and never counted as "upcoming" — the shop's own page has the details.
  """

  use CoreWeb, :controller

  alias Core.Repo
  alias Stacks.Enrichment.Events

  @doc "GET /api/authors/:id/events"
  def index(conn, %{"id" => author_id}) do
    events =
      author_id
      |> Events.listed_events_for_author()
      |> Repo.preload(:store)
      |> Enum.map(&event_json/1)

    json(conn, %{events: events})
  rescue
    Ecto.Query.CastError -> json(conn, %{events: []})
  end

  defp event_json(event) do
    %{
      id: event.id,
      title: event.title,
      event_date: event.event_date && DateTime.to_iso8601(event.event_date),
      location: event.location,
      url: event.url,
      store_name: store_name(event)
    }
  end

  defp store_name(%{store: %{name: name}}) when is_binary(name), do: name
  defp store_name(_), do: nil
end
