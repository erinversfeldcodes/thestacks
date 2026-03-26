defmodule StacksWeb.BookController do
  @moduledoc "Handles book detail retrieval by ID or ISBN."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Blog
  alias Stacks.Books
  alias Stacks.Books.BookDetailCache
  alias Stacks.Shelving
  alias Stacks.Visibility
  alias StacksWeb.Plugs.AgeGate
  alias StacksWeb.ProtoJSON

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  @doc "POST /api/books — resolve an ISBN and create the book (manual entry, US-1.1.5)."
  def create(conn, %{"isbn" => isbn}) do
    case Books.create_from_isbn(isbn) do
      {:ok, book} ->
        conn
        |> put_status(201)
        |> json(%{book: ProtoJSON.book(book)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(changeset)})

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
        |> json(%{book: ProtoJSON.book(book), placement: ProtoJSON.book_placement(placement)})

      {:ok, :existing, book, placement} ->
        json(conn, %{
          book: ProtoJSON.book(book),
          placement: ProtoJSON.book_placement(placement),
          source: "catalogue"
        })

      {:ok, :already_placed, book, placement} ->
        json(conn, %{
          book: ProtoJSON.book(book),
          placement: ProtoJSON.book_placement(placement),
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
        |> json(%{error: "validation_failed", details: format_errors(changeset)})

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
        json(conn, %{edition: ProtoJSON.edition(edition)})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})

      {:error, :duplicate_isbn} ->
        conn
        |> put_status(422)
        |> json(%{error: "duplicate_isbn"})

      {:error, :isbn_not_found} ->
        conn
        |> put_status(422)
        |> json(%{error: "isbn_not_found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(changeset)})
    end
  end

  @doc "GET /api/books/:id — retrieve a book by UUID."
  def show(conn, %{"id" => id}) do
    book = cached_or_fetch(id)

    case book do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      book ->
        conn = AgeGate.enforce(conn, book)
        render_book_detail(conn, book, id)
    end
  end

  defp cached_or_fetch(id) do
    case BookDetailCache.get(id) do
      {:ok, cached} -> cached
      {:miss, _} -> fetch_and_cache_book(id)
    end
  end

  defp render_book_detail(conn, book, id) do
    viewer = build_viewer(conn)

    cond do
      conn.halted ->
        conn

      Visibility.resolve_visibility(book, viewer) == :hidden ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      true ->
        placement = lookup_placement(conn, id)
        count = Books.community_read_count(book.id)
        my_writing = my_writing_for(conn, id)

        json(conn, %{
          book: ProtoJSON.book(book, community_read_count: count),
          placement: ProtoJSON.book_placement(placement),
          my_writing:
            Enum.map(my_writing, &%{id: &1.id, title: &1.title, published_at: &1.published_at})
        })
    end
  end

  defp my_writing_for(conn, book_id) do
    case Guardian.Plug.current_resource(conn) do
      nil -> []
      user -> Blog.list_posts_for_book_by_user(book_id, user.id)
    end
  end

  defp fetch_and_cache_book(id) do
    case Books.get_book_detail(id) do
      nil ->
        nil

      book ->
        BookDetailCache.put(id, book)
        book
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
          json(conn, %{book: ProtoJSON.book(book)})
        end
    end
  end

  defp build_viewer(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> :unauthenticated
      %{id: id} -> {:platform_user, id}
    end
  end

  defp lookup_placement(conn, book_id) do
    case Guardian.Plug.current_resource(conn) do
      nil -> nil
      user -> Shelving.get_placement_for_book(user.id, book_id)
    end
  end
end
