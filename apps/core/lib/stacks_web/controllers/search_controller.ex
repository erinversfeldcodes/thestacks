defmodule StacksWeb.SearchController do
  @moduledoc "Handles full-text book search."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Marketplace
  alias Stacks.Scope
  alias Stacks.Shelving
  alias Stacks.Visibility
  alias StacksWeb.ProtoJSON

  @doc """
      GET /api/search?q=… — sectioned full-text search over book titles. `collection` = the viewer's own active-placement matches (no
      provenance); `platform_hits` = platform-visible books excluding the
      viewer's collection, each with optional discovery provenance (listing /
      looking_for_home). `results` is DEPRECATED: always empty, key kept
      for wire-compat, proto field number reserved.

      Anonymous callers get the catalogue slice and nothing else: an empty
      `collection`, and `platform_hits` stripped of provenance. Both of the
      segments withheld are derived from someone's shelf — the caller's own in
      `collection`, another reader's handle and asking price in the labels — so
      they sit at the platform tier, and the one gate that decides it is the
      viewer here rather than a rule repeated per segment.
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
    labels = discovery_labels(viewer, platform_books)

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

  defp discovery_labels(:unauthenticated, _books), do: %{}

  # ⛔ Both label reads run inside the viewer's scope, though only one needs it
  # today. `looking_for_home_labels/1` joins `op.bookshelves` and
  # `op.bookshelf_placements`, which carry row-level policies under FORCE, so an
  # unscoped call does not return an empty list — it RAISES
  # `42501 query on a row-level-secured table with no request scope set`, and the
  # entire search answers 500 to every signed-in reader. Measured on a deployed
  # stack: authenticated 500 at both scopes, anonymous 200, because the clause
  # above returns before the query. ⚠️ It raises while evaluating the policy, so
  # an empty table fails exactly the same way — row count is not the variable.
  #
  # `op.listings` carries no policies, so the listing read would survive on its
  # own. It is wrapped anyway: both are reads of someone else's shelf, and
  # splitting the pair would leave the next reader to work out which half needs
  # a scope and why.
  #
  # ⚠️ The scope is established here, not inside the two helpers. The placement
  # lookups elsewhere scope themselves because each always knows its user; these
  # two deliberately do not — they take book ids and are cross-user by design, so
  # the caller is the only place that holds a viewer to scope to.
  #
  # ⚠️ ONLY ONE OF THE TWO IS ACTUALLY REFUSED WITHOUT A SCOPE, and the wrapper
  # is kept around both anyway. `looking_for_home_labels/1` reads
  # `op.bookshelf_placements` joined to `op.bookshelves`, which are row-level
  # secured; `active_listing_labels/1` reads `op.listings` joined to `op.users`,
  # and neither of those is. Measured 2026-11-07.
  #
  # ⛔ So if the `looking_for_home` call ever moves out of this block, the
  # wrapper will look redundant around what remains and removing it will appear
  # safe. It is that call, not the pairing, that makes this load-bearing.
  # `search_labels_need_a_scope_test.exs` holds both halves of that measurement.
  #
  # ⚖️ Not narrowed to the one call that needs it: the grouping says "these are
  # the cross-user lookups", which is the thing a reader needs to know, and a
  # minimal scope buys nothing here.
  defp discovery_labels({:platform_user, user_id}, books) do
    book_ids = Enum.map(books, & &1.id)

    Scope.for_viewer(user_id, fn ->
      lfh = Shelving.looking_for_home_labels(book_ids)
      listed = Marketplace.active_listing_labels(book_ids)
      Map.merge(lfh, listed)
    end)
  end

  defp parse_limit(nil), do: 20

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 and n <= 100 -> n
      _ -> 20
    end
  end
end
