defmodule StacksWeb.BookController do
  @moduledoc "Handles book detail retrieval by ID or ISBN."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Books
  alias Stacks.Shelving
  alias Stacks.Visibility
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

  @doc """
  POST /api/books/confirm — second step of the interactive two-step upload flow.

  Accepts `{"isbn": "...", "shelf_name": "..."}` (shelf_name is optional).
  Looks up or creates the book (work + edition) for the given ISBN.

  Returns:
  - 200 `{book: ...}` when the book is found or created successfully.
  - 409 `{error: "merge_required", work_id: "..."}` when the ISBN metadata matches
    an existing work that does not yet have this edition.
  - 422 on validation errors or missing `isbn` param.
  """
  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case Books.confirm(user.id, params) do
      {:ok, :created, book} ->
        book = Books.get_book_detail(book.id)
        placement = Shelving.get_placement_for_book(user.id, book.id)

        conn
        |> put_status(201)
        |> json(%{book: format_book(book), placement: format_placement_or_nil(placement)})

      {:ok, :existing, book, placement} ->
        json(conn, %{
          book: format_book(book),
          placement: format_placement_or_nil(placement),
          source: "catalogue"
        })

      {:ok, :already_placed, book, placement} ->
        json(conn, %{
          book: format_book(book),
          placement: format_placement_or_nil(placement),
          source: "collection"
        })

      {:error, {:merge_required, work_id}} ->
        conn
        |> put_status(409)
        |> json(%{error: "merge_required", work_id: work_id})

      {:error, :missing_isbn} ->
        conn
        |> put_status(422)
        |> json(%{error: "isbn is required"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_changeset_errors(changeset)})

      {:error, _reason} ->
        conn
        |> put_status(422)
        |> json(%{error: "isbn_not_found"})
    end
  end

  @doc """
  POST /api/books/:id/merge-format — add a new edition (ISBN/format) to an existing book (work).

  Accepts `{"isbn": "...", "format_label": "..."}` (format_label is optional).
  Merges the given edition into the book identified by `:id`.

  Returns:
  - 200 `{edition: ...}` on success.
  - 404 when the book `:id` does not exist.
  - 422 `{error: "duplicate_isbn"}` when the ISBN is already registered to any edition.
  - 422 on other validation failures.
  """
  @spec merge_format(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def merge_format(conn, %{"id" => book_id} = params) do
    case Books.merge_edition(book_id, params) do
      {:ok, edition} ->
        json(conn, %{edition: format_edition(edition)})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})

      {:error, :duplicate_isbn} ->
        conn
        |> put_status(422)
        |> json(%{error: "duplicate_isbn"})

      {:error, %Ecto.Changeset{} = changeset} ->
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
        viewer = build_viewer(conn)

        cond do
          conn.halted ->
            conn

          Visibility.resolve_visibility(book, viewer) == :hidden ->
            conn |> put_status(404) |> json(%{error: "not_found"})

          true ->
            placement = lookup_placement(conn, id)
            count = Books.community_read_count(book.id)

            json(conn, %{
              book: format_book(book, count),
              placement: format_placement_or_nil(placement)
            })
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

  defp build_viewer(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> :unauthenticated
      %{id: id} -> {:platform_user, id}
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
      book_id: placement.book_id,
      bookshelf_name: placement.bookshelf.name,
      formats: placement.formats || [],
      personal_rating: placement.personal_rating,
      notes: placement.notes
    }
  end

  defp format_book(book, community_read_count \\ 0) do
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
      primary_edition: format_edition_or_nil(primary),
      community_read_count: community_read_count
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
