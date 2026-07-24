defmodule StacksWeb.SearchController do
  @moduledoc "Handles full-text book search."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Marketplace
  alias Stacks.Shelving
  alias Stacks.Visibility
  alias StacksWeb.ProtoJSON

  @doc """
  GET /api/search?q=... — full-text search across book titles, sectioned (#285).

  The response carries three views of the same query:

    * `results` — the flat, backward-compatible list of platform-visible books
      (the pre-#285 shape the current Elm decoder still reads).
    * `collection` — "Your Collection": the viewer's own active-placement title
      matches, as `SearchHit`s with no provenance (owned by the viewer).
    * `platform_hits` — "On the Platform": the platform-visible books EXCLUDING
      those already in the viewer's collection, each a `SearchHit` carrying
      optional discovery-source provenance (an active marketplace listing →
      "listed" + handle + price; an always-visible `looking_for_home` placement
      → "looking_for_home" + handle). An active listing takes precedence over a
      looking_for_home label. Ordinary private placements leak no provenance.
  """
  def index(conn, %{"q" => query}) when is_binary(query) and query != "" do
    limit = parse_limit(conn.params["limit"])
    viewer = build_viewer(conn)

    platform_books =
      query
      |> Books.search_books(limit: limit)
      |> Enum.filter(&Visibility.can_view?(&1, viewer))

    collection_books = collection_section(viewer, query, limit)
    collection_ids = MapSet.new(collection_books, & &1.id)
    labels = discovery_labels(platform_books)

    platform_hits =
      platform_books
      |> Enum.reject(&MapSet.member?(collection_ids, &1.id))
      |> Enum.map(fn book -> ProtoJSON.search_hit(book, Map.get(labels, book.id, %{})) end)

    json(conn, %{
      query: query,
      count: length(platform_books),
      results: Enum.map(platform_books, &ProtoJSON.search_book/1),
      collection: Enum.map(collection_books, &ProtoJSON.search_hit/1),
      platform_hits: platform_hits
    })
  end

  def index(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "query parameter 'q' is required"})
  end

  defp build_viewer(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> :unauthenticated
      %{id: id} -> {:platform_user, id}
    end
  end

  # "Your Collection": only an authenticated viewer has one.
  defp collection_section({:platform_user, user_id}, query, limit) do
    Shelving.search_collection(user_id, query, limit: limit)
  end

  defp collection_section(:unauthenticated, _query, _limit), do: []

  # Merges the two discovery-label sources into a `%{book_id => label}` map for
  # the given platform books. "listed" (active marketplace listing, carries a
  # price) takes precedence over "looking_for_home" (always-visible advert) when
  # a book has both — Map.merge/2 lets the listed map win on key collision.
  defp discovery_labels(books) do
    book_ids = Enum.map(books, & &1.id)
    lfh = Shelving.looking_for_home_labels(book_ids)
    listed = Marketplace.active_listing_labels(book_ids)
    Map.merge(lfh, listed)
  end

  defp parse_limit(nil), do: 20

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 and n <= 100 -> n
      _ -> 20
    end
  end
end
