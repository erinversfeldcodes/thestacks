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

  The response carries two sectioned views of the same query:

    * `results` — DEPRECATED (#298): always an empty list. The flat, pre-#285
      list is no longer populated — the SPA reads only the sectioned fields
      (`collection`/`platform_hits`) since #285/#292 and drops `results`. The
      proto field number stays reserved; the key is kept for wire-compat.
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
    scope = parse_scope(conn.params["scope"])
    viewer = build_viewer(conn)

    platform_books =
      query
      |> Books.search_books(limit: limit, scope: scope)
      |> Enum.filter(&Visibility.can_view?(&1, viewer))

    collection = collection_section(viewer, query, limit, scope)
    collection_ids = MapSet.new(collection, & &1.book.id)
    labels = discovery_labels(platform_books)

    # Deep search (#284): a `ts_headline` excerpt for every hit — collection or
    # platform — whose DESCRIPTION matched. Title-only hits (and every hit under
    # the default title scope) are absent from the map and carry an empty snippet.
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
      # Total DISTINCT books returned across both sections. `platform_hits`
      # already excludes the viewer's collection books (de-duped above), so the
      # two counts never overlap (#298).
      count: length(collection) + length(platform_hits),
      # Deprecated (#298): `results` (proto field 3) is no longer populated. The
      # field number stays reserved on the wire — never reused — but the SPA
      # decodes-and-drops it (it reads only `collection`/`platform_hits` since
      # #285/#292), so serialising a flat list was pure wasted work.
      results: [],
      collection:
        Enum.map(collection, fn %{book: book, bookshelf_name: name} ->
          ProtoJSON.search_hit(book, put_snippet(%{bookshelf_name: name}, snippets, book.id))
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

  # "Your Collection": only an authenticated viewer has one. `scope` (:title |
  # :deep) is threaded through so deep search covers the collection section too.
  defp collection_section({:platform_user, user_id}, query, limit, scope) do
    Shelving.search_collection(user_id, query, limit: limit, scope: scope)
  end

  defp collection_section(:unauthenticated, _query, _limit, _scope), do: []

  # Only `scope=deep` enables description matching; anything else is title-only.
  defp parse_scope("deep"), do: :deep
  defp parse_scope(_), do: :title

  # Under deep scope, build the `%{book_id => snippet}` map over the union of the
  # platform + collection hit ids. Title scope skips the extra query entirely.
  defp deep_snippets(:deep, query, platform_books, collection) do
    ids =
      (Enum.map(platform_books, & &1.id) ++ Enum.map(collection, & &1.book.id))
      |> Enum.uniq()

    Books.description_snippets(ids, query)
  end

  defp deep_snippets(_title, _query, _platform_books, _collection), do: %{}

  # Attach the `:snippet` label only when this book matched on its description.
  defp put_snippet(label, snippets, book_id) do
    case Map.get(snippets, book_id) do
      nil -> label
      snippet -> Map.put(label, :snippet, snippet)
    end
  end

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
