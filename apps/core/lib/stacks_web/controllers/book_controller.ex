defmodule StacksWeb.BookController do
  @moduledoc "Handles book detail retrieval by ID or ISBN."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Shelving
  alias StacksWeb.Plugs.AgeGate

  @doc "POST /api/books — resolve an ISBN and create the book (manual entry, US-1.1.5)."
  def create(conn, %{"isbn" => isbn}) do
    case Books.create_from_isbn(isbn) do
      {:ok, book} ->
        conn
        |> put_status(201)
        |> json(%{book: format_book(book)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_changeset_errors(changeset)})

      {:error, _} ->
        conn
        |> put_status(422)
        |> json(%{error: "isbn_not_found"})
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
          placement = lookup_placement(conn, id)
          json(conn, %{book: format_book(book), placement: format_placement_or_nil(placement)})
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

  defp lookup_placement(conn, book_id) do
    case Guardian.Plug.current_resource(conn) do
      nil -> nil
      user -> Shelving.get_placement_for_book(user.id, book_id)
    end
  end

  defp format_placement_or_nil(nil), do: nil

  defp format_placement_or_nil(placement) do
    %{
      id: placement.id,
      bookshelf_name: placement.bookshelf.name,
      formats: placement.formats || [],
      personal_rating: placement.personal_rating,
      notes: placement.notes
    }
  end

  defp format_book(book) do
    editions = format_editions(book)
    primary = Books.primary_edition(book)

    %{
      id: book.id,
      title: book.title,
      description: book.description,
      language: book.language,
      subjects: book.subjects,
      bisac_codes: book.bisac_codes,
      visibility_tier: book.visibility_tier,
      author: format_author(book.author),
      editions: editions,
      edition_count: length(editions),
      primary_edition: format_edition_or_nil(primary)
    }
  end

  defp format_author(%Ecto.Association.NotLoaded{}), do: nil
  defp format_author(nil), do: nil

  defp format_author(author) do
    %{id: author.id, name: author.name, bio: author.bio, website: author.website_url}
  end

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
