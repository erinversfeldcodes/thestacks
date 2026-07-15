defmodule StacksWeb.CatalogueController do
  @moduledoc """
  Public catalogue controller for browsing all books in the system.

  Returns paginated book metadata without any ownership information.
  No user IDs, shelf names, placement data, or aggregate ownership
  counts are ever included in the response.
  """

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias StacksWeb.ProtoJSON

  @doc """
  GET /api/catalogue — returns a paginated list of books.

  Query parameters:
    * `search` — free-text search (title/author)
    * `subject` — filter by subject/genre
    * `sort` — one of "title", "author", "recent" (default "title")
    * `page` — 1-based page number (default 1)
    * `per_page` — items per page (default 24, max 100)
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    opts = [
      search: params["search"],
      subject: params["subject"],
      sort: params["sort"] || "title",
      page: parse_int(params["page"], 1),
      per_page: parse_int(params["per_page"], 24)
    ]

    # #229: forward the viewer's age-verified status so age-gated books are hidden
    # from an authenticated-but-unverified viewer (as they already are anonymously),
    # while remaining visible to a verified viewer. Normalise nil → false.
    viewer =
      case Guardian.Plug.current_resource(conn) do
        nil -> :unauthenticated
        user -> {:platform_user, user.id, user.age_verified == true}
      end

    {books, total} = Books.list_catalogue([{:viewer, viewer} | opts])

    json(conn, %{
      books: Enum.map(books, &ProtoJSON.catalogue_book/1),
      total: total,
      page: opts[:page],
      per_page: opts[:per_page]
    })
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
