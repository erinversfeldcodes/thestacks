defmodule StacksWeb.SearchController do
  @moduledoc "Handles full-text book search."

  use CoreWeb, :controller

  alias Stacks.Books

  @doc "GET /api/search?q=... — full-text search across book titles."
  def index(conn, %{"q" => query}) when is_binary(query) and query != "" do
    limit = parse_limit(conn.params["limit"])
    books = Books.search_books(query, limit: limit)

    json(conn, %{
      query: query,
      count: length(books),
      results: Enum.map(books, &format_book/1)
    })
  end

  def index(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "query parameter 'q' is required"})
  end

  defp parse_limit(nil), do: 20

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 and n <= 100 -> n
      _ -> 20
    end
  end

  defp format_book(book) do
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
      cover_image_url: book.cover_image_url,
      publication_year: book.publication_year,
      visibility_tier: book.visibility_tier,
      author: author
    }
  end
end
