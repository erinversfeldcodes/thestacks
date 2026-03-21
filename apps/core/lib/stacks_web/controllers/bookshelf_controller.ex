defmodule StacksWeb.BookshelfController do
  @moduledoc "Returns books on a named bookshelf for the current user."

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving
  alias Stacks.Visibility
  alias StacksWeb.Plugs.ViewAsPlug

  @valid_bookshelves ~w(antilibrary library wishlist reading_pile looking_for_home)

  @doc "GET /api/bookshelves/:bookshelf_name — list all active placements on a bookshelf."
  def show(conn, %{"bookshelf_name" => bookshelf_name}) do
    if bookshelf_name in @valid_bookshelves do
      user = Guardian.Plug.current_resource(conn)
      conn = ViewAsPlug.authorize_view_as(conn, user.id)

      if conn.halted do
        conn
      else
        viewer = Map.get(conn.assigns, :view_as_context, {:platform_user, user.id})
        render_bookshelf(conn, user, bookshelf_name, viewer)
      end
    else
      conn
      |> put_status(404)
      |> json(%{error: "invalid bookshelf name"})
    end
  end

  @doc "PUT /api/bookshelves/:id/visibility — update the visibility of a bookshelf."
  def update_visibility(conn, %{"id" => bookshelf_id, "visibility" => visibility}) do
    user = Guardian.Plug.current_resource(conn)

    case Shelving.update_bookshelf_visibility(bookshelf_id, user.id, visibility) do
      {:ok, bookshelf} ->
        json(conn, %{id: bookshelf.id, visibility: bookshelf.visibility})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_visibility(conn, _params) do
    conn |> put_status(422) |> json(%{error: "visibility is required"})
  end

  defp render_bookshelf(conn, user, bookshelf_name, viewer) do
    case Shelving.get_bookshelf(user.id, bookshelf_name) do
      nil ->
        json(conn, %{bookshelf: bookshelf_name, count: 0, placements: []})

      bookshelf ->
        render_visible_bookshelf(conn, user, bookshelf_name, bookshelf, viewer)
    end
  end

  defp render_visible_bookshelf(conn, user, bookshelf_name, bookshelf, viewer) do
    if Visibility.resolve_visibility(bookshelf, viewer) == :hidden do
      conn |> put_status(404) |> json(%{error: "not_found"})
    else
      placements =
        user.id
        |> Shelving.get_bookshelf_books(bookshelf_name)
        |> Enum.filter(&(Visibility.resolve_visibility(&1, viewer) == :visible))

      json(conn, %{
        bookshelf: bookshelf_name,
        count: length(placements),
        placements: Enum.map(placements, &format_placement/1)
      })
    end
  end

  defp format_placement(placement) do
    book =
      case placement.book do
        %Ecto.Association.NotLoaded{} ->
          nil

        nil ->
          nil

        b ->
          primary = Stacks.Books.primary_edition(b)

          editions =
            case b.editions do
              list when is_list(list) -> Enum.map(list, &format_edition/1)
              _ -> []
            end

          %{
            id: b.id,
            title: b.title,
            description: b.description,
            visibility_tier: b.visibility_tier,
            author: format_author(b.author),
            editions: editions,
            edition_count: length(editions),
            primary_edition: format_edition_or_nil(primary)
          }
      end

    %{
      id: placement.id,
      position: placement.position,
      placed_at: placement.placed_at,
      formats: placement.formats,
      personal_rating: placement.personal_rating,
      notes: placement.notes,
      book: book
    }
  end

  defp format_author(%Ecto.Association.NotLoaded{}), do: nil
  defp format_author(nil), do: nil

  defp format_author(author) do
    %{
      id: author.id,
      name: author.name,
      bio: nil
    }
  end

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
