defmodule StacksWeb.BookController do
  @moduledoc "Handles book detail retrieval by ID or ISBN."

  use CoreWeb, :controller

  alias Stacks.Books
  alias StacksWeb.Plugs.AgeGate

  @doc "POST /api/books — resolve an ISBN and create the book (manual entry, US-1.1.5)."
  def create(conn, %{"isbn" => isbn}) do
    case Books.create_from_isbn(isbn) do
      {:ok, book} ->
        conn
        |> put_status(201)
        |> json(%{book: format_book(book)})

      {:error, :not_found} ->
        conn
        |> put_status(422)
        |> json(%{error: "isbn_not_found"})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_changeset_errors(changeset)})
    end
  end

  @doc "GET /api/books/:id — retrieve a book by UUID."
  def show(conn, %{"id" => id}) do
    case Books.get_book_detail(id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})

      book ->
        conn = AgeGate.enforce(conn, book)

        if conn.halted do
          conn
        else
          json(conn, %{book: format_book(book)})
        end
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
        conn = AgeGate.enforce(conn, book)

        if conn.halted do
          conn
        else
          json(conn, %{book: format_book(book)})
        end
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
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
