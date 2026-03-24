defmodule StacksWeb.SearchController do
  @moduledoc "Handles full-text book search."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Visibility
  alias StacksWeb.ProtoJSON

  @doc "GET /api/search?q=... — full-text search across book titles."
  def index(conn, %{"q" => query}) when is_binary(query) and query != "" do
    limit = parse_limit(conn.params["limit"])
    viewer = build_viewer(conn)
    books = Books.search_books(query, limit: limit)
    visible_books = Enum.filter(books, &Visibility.can_view?(&1, viewer))

    json(conn, %{
      query: query,
      count: length(visible_books),
      results: Enum.map(visible_books, &ProtoJSON.search_book/1)
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

  defp parse_limit(nil), do: 20

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 and n <= 100 -> n
      _ -> 20
    end
  end
end
