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
          %{
            id: b.id,
            isbn: b.isbn,
            title: b.title,
            cover_image_url: b.cover_image_url,
            page_count: b.page_count
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
end
