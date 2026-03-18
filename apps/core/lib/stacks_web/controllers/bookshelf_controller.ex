defmodule StacksWeb.BookshelfController do
  @moduledoc "Returns books on a named bookshelf for the current user."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving

  @valid_bookshelves ~w(antilibrary library wishlist reading_pile looking_for_home)

  @doc "GET /api/bookshelves/:bookshelf_name — list all active placements on a bookshelf."
  def show(conn, %{"bookshelf_name" => bookshelf_name}) do
    if bookshelf_name in @valid_bookshelves do
      user = Guardian.Plug.current_resource(conn)
      placements = Shelving.get_bookshelf_books(user.id, bookshelf_name)

      json(conn, %{
        bookshelf: bookshelf_name,
        count: length(placements),
        placements: Enum.map(placements, &format_placement/1)
      })
    else
      conn
      |> put_status(404)
      |> json(%{error: "invalid bookshelf name"})
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
