defmodule StacksWeb.AuthorEventsController do
  @moduledoc """
      Public read for an author's bookstore events (item 4: "surface
      events" — the book-detail author card's "Events coming soon" placeholder
      finally has something to say).

      Public because the data is: these are events scraped from bookshops' own
      public pages, carrying nothing about any reader. Dateless events are listed
      last and never counted as "upcoming" — the shop's own page has the details.
  """

  use CoreWeb, :controller

  alias Core.Repo
  alias Stacks.Enrichment.Events

  @doc """
      GET /api/authors/:id/events

      An id that is not an id is a 400; an id that is well-formed but names
      nobody is a 200 with an empty list. The two used to be the same answer,
      and that made a caller bug permanently invisible — send a slug or a name
      where a UUID belongs and the card says "no events" forever, which is a
      sentence about the author rather than about the request. The empty list
      stays the answer for an unknown author: it is the truthful one, and it
      keeps the endpoint from reporting who exists.
  """
  def index(conn, %{"id" => author_id}) do
    case Ecto.UUID.cast(author_id) do
      {:ok, id} ->
        events =
          id
          |> Events.listed_events_for_author()
          |> Repo.preload(:store)
          |> Enum.map(&event_json/1)

        json(conn, %{events: events})

      :error ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_author_id"})
    end
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
