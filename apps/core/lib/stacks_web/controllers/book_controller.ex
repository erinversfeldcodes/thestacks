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
        # Decision (#333): the book was created by this very request, so there
        # is exactly one placement by construction — but asking for "the one"
        # is the assumption that broke `show`. Ask for the list and serialise
        # all of it; the 201 then carries the same shape as every other branch.
        placements = Shelving.get_placements_for_book(user.id, book.id)

        conn
        |> put_status(201)
        |> json(confirm_payload(book, placements, List.first(placements), nil))

      {:ok, :existing, book, placement, placements} ->
        json(conn, confirm_payload(book, placements, placement, "catalogue"))

      {:ok, :already_placed, book, placement, placements} ->
        json(conn, confirm_payload(book, placements, placement, "collection"))

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

  # `placement` is the one this request produced or matched; `placements` is
  # every active placement the user now has of this book. When there is more
  # than one the client informs ("also on your Wish List") — it never blocks.
  defp confirm_payload(book, placements, placement, source) do
    payload = %{
      book: ProtoJSON.book(book),
      placement: ProtoJSON.book_placement(placement),
      placements: Enum.map(placements, &ProtoJSON.book_placement/1)
    }

    if source, do: Map.put(payload, :source, source), else: payload
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

  @doc """
  PUT /api/books/:id/age-gate — the person who added a book raises its age
  gate (marks it "adults only"). Body: `{"adults_only": true}` (also accepts
  `{"age_gated": true}`).

  Raise-only (user path): a user may only RAISE the gate (`public →
  age_gated`); attempting to lower it (`age_gated → public`) returns 403 —
  only the platform owner may un-gate. `visibility_tier` is not PII; no new
  personal data is introduced.

  Returns 200 with the updated book JSON, 403 on a raise-only violation,
  404 when the book is missing.
  """
  @spec set_age_gate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def set_age_gate(conn, %{"id" => id} = params) do
    tier = if age_gate_requested?(params), do: "age_gated", else: "public"

    case Books.set_visibility_tier(id, tier, source: :user, raise_only: true) do
      {:ok, book} ->
        json(conn, %{book: ProtoJSON.book(Books.get_book_detail(book.id))})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(changeset)})
    end
  end

  # The endpoint's purpose is marking a book adults-only, so a missing flag
  # defaults to raising the gate. An explicit falsey flag on an age-gated
  # book is a lower attempt, which the raise-only guard rejects with 403.
  defp age_gate_requested?(%{"adults_only" => value}), do: truthy?(value)
  defp age_gate_requested?(%{"age_gated" => value}), do: truthy?(value)
  defp age_gate_requested?(_params), do: true

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_other), do: false

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

      # Defense-in-depth (#295 d): upstream filter/age-gate should keep :hidden unreachable here; 404 rather than leak.
      Visibility.resolve_visibility(book, viewer) == :hidden ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      true ->
        placements = lookup_placements(conn, id)
        count = Books.community_read_count(book.id)
        my_writing = my_writing_for(conn, id)

        json(conn, %{
          book: ProtoJSON.book(book, community_read_count: count),
          placement: ProtoJSON.book_placement(List.first(placements)),
          placements: Enum.map(placements, &ProtoJSON.book_placement/1),
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

  @doc """
  GET /api/books/isbn/:isbn — retrieve a book by ISBN.

  This is the manual-ISBN entry path. It carries the viewer's existing
  placements (#333) so the client can tell them the book is already in their
  collection, and on which bookshelves, *before* they place it again. The
  photo path has had that awareness since the SSE payload's `is_duplicate`;
  this is its manual-path equivalent. It is purely informational — nothing
  here refuses the lookup or the placement that follows.
  """
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
          placements = lookup_placements(conn, book.id)

          json(conn, %{
            book: ProtoJSON.book(book),
            placement: ProtoJSON.book_placement(List.first(placements)),
            placements: Enum.map(placements, &ProtoJSON.book_placement/1)
          })
        end
    end
  end

  defp build_viewer(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> :unauthenticated
      %{id: id} -> {:platform_user, id}
    end
  end

  # Decision (#333): the detail response carries ALL of the viewer's placements
  # of this book. This call site is the live 500 — it fed `Repo.one()`, so the
  # owner of a book sitting on two bookshelves got `Ecto.MultipleResultsError`
  # on their own book detail. It is also the surface that must *show* the
  # multi-shelf state, so a list is what it wanted all along; the singular
  # `placement` key stays as the first (oldest) entry for wire compatibility.
  defp lookup_placements(conn, book_id) do
    case Guardian.Plug.current_resource(conn) do
      nil -> []
      user -> Shelving.get_placements_for_book(user.id, book_id)
    end
  end
end
