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
      GET /api/search?q=… — sectioned full-text search over book titles. `collection` = the viewer's own active-placement matches (no
      provenance); `platform_hits` = platform-visible books excluding the
      viewer's collection, each with optional discovery provenance (listing /
      looking_for_home). `results` is DEPRECATED: always empty, key kept
      for wire-compat, proto field number reserved. Anonymous callers get only
      `platform_hits`.
  """
  def index(conn, %{"q" => query}) when is_binary(query) and query != "" do
    limit = parse_limit(conn.params["limit"])
    scope = parse_scope(conn.params["scope"])
    viewer = build_viewer(conn)

    platform_books =
      query
      |> Books.search_books(limit: limit, scope: scope)
      |> Enum.filter(&Visibility.can_view?(&1, viewer))

    collection = collection_section(viewer, query, limit, scope)
    collection_ids = MapSet.new(collection, & &1.book.id)
    labels = discovery_labels(platform_books)

    snippets = deep_snippets(scope, query, platform_books, collection)

    platform_hits =
      platform_books
      |> Enum.reject(&MapSet.member?(collection_ids, &1.id))
      |> Enum.map(fn book ->
        label = labels |> Map.get(book.id, %{}) |> put_snippet(snippets, book.id)
        ProtoJSON.search_hit(book, label)
      end)

    json(conn, %{
      query: query,
      count: length(collection) + length(platform_hits),
      results: [],
      collection:
        Enum.map(collection, fn %{book: book, bookshelf_name: name, bookshelf_names: names} ->
          label = %{bookshelf_name: name, bookshelf_names: names}
          ProtoJSON.search_hit(book, put_snippet(label, snippets, book.id))
        end),
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

  defp collection_section({:platform_user, user_id}, query, limit, scope) do
    Shelving.search_collection(user_id, query, limit: limit, scope: scope)
  end

  defp collection_section(:unauthenticated, _query, _limit, _scope), do: []

  defp parse_scope("deep"), do: :deep
  defp parse_scope(_), do: :title

  defp deep_snippets(:deep, query, platform_books, collection) do
    ids =
      (Enum.map(platform_books, & &1.id) ++ Enum.map(collection, & &1.book.id))
      |> Enum.uniq()

    Books.description_snippets(ids, query)
  end

  defp deep_snippets(_title, _query, _platform_books, _collection), do: %{}

  defp put_snippet(label, snippets, book_id) do
    case Map.get(snippets, book_id) do
      nil -> label
      snippet -> Map.put(label, :snippet, snippet)
    end
  end

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
