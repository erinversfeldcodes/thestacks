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

    viewer =
      case Guardian.Plug.current_resource(conn) do
        nil -> :unauthenticated
        user -> {:platform_user, user.id}
      end

    {books, total} = Books.list_catalogue([{:viewer, viewer} | opts])

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
    editions = format_editions(book)
    primary = Books.primary_edition(book)

    %{
      id: book.id,
      title: book.title,
      author: format_author(book.author),
      subjects: book.subjects,
      visibility_tier: book.visibility_tier,
      editions: editions,
      edition_count: length(editions),
      primary_edition: format_edition_or_nil(primary)
    }
  end

  defp format_author(%Ecto.Association.NotLoaded{}), do: nil
  defp format_author(nil), do: nil
  defp format_author(author), do: %{id: author.id, name: author.name}

  defp format_editions(%{editions: editions}) when is_list(editions) do
    Enum.map(editions, &format_edition/1)
  end

  defp format_editions(_), do: []

  defp format_edition(edition) do
    %{
      id: edition.id,
      isbn: edition.isbn,
      format_label: edition.format_label,
      cover_image_url: edition.cover_image_url,
      page_count: edition.page_count,
      publisher: edition.publisher,
      publication_year: edition.publication_year,
      is_primary: edition.is_primary
    }
  end

  defp format_edition_or_nil(nil), do: nil
  defp format_edition_or_nil(edition), do: format_edition(edition)
end
