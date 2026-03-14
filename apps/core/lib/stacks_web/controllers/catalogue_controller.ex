defmodule StacksWeb.CatalogueController do
  @moduledoc """
  Public catalogue controller for browsing all books in the system.

  Returns paginated book metadata without any ownership information.
  No user IDs, shelf names, placement data, or aggregate ownership
  counts are ever included in the response.
  """

  use CoreWeb, :controller

  alias Stacks.Books

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

    {books, total} = Books.list_catalogue(opts)

    json(conn, %{
      books: Enum.map(books, &format_catalogue_book/1),
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

  defp format_catalogue_book(book) do
    author =
      case book.author do
        %Ecto.Association.NotLoaded{} -> nil
        nil -> nil
        author -> %{id: author.id, name: author.name}
      end

    %{
      id: book.id,
      isbn: book.isbn,
      title: book.title,
      author: author,
      cover_image_url: book.cover_image_url,
      page_count: book.page_count,
      subjects: book.subjects,
      publication_year: book.publication_year,
      visibility_tier: book.visibility_tier
    }
  end
end
