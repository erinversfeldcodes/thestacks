defmodule StacksWeb.BookController do
  @moduledoc "Handles book detail retrieval by ID or ISBN."

  use CoreWeb, :controller

  alias Stacks.Books

  @doc "GET /api/books/:id — retrieve a book by UUID."
  def show(conn, %{"id" => id}) do
    case Books.get_book_detail(id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})

      book ->
        json(conn, %{book: format_book(book)})
    end
  end

  @doc "GET /api/books/isbn/:isbn — retrieve a book by ISBN."
  def show_by_isbn(conn, %{"isbn" => isbn}) do
    case Books.find_existing(isbn) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})

      book ->
        json(conn, %{book: format_book(book)})
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
      description: book.description,
      cover_image_url: book.cover_image_url,
      page_count: book.page_count,
      publisher: book.publisher,
      publication_year: book.publication_year,
      language: book.language,
      subjects: book.subjects,
      bisac_codes: book.bisac_codes,
      visibility_tier: book.visibility_tier,
      author: author
    }
  end
end
