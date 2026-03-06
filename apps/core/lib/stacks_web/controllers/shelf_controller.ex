defmodule StacksWeb.ShelfController do
  @moduledoc "Returns books on a named shelf for the current user."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving

  @valid_shelves ~w(antilibrary library wishlist reading_pile looking_for_home)

  @doc "GET /api/shelves/:shelf_name — list all active placements on a shelf."
  def show(conn, %{"shelf_name" => shelf_name}) do
    if shelf_name in @valid_shelves do
      user = Guardian.Plug.current_resource(conn)
      placements = Shelving.get_shelf_books(user.id, shelf_name)

      json(conn, %{
        shelf: shelf_name,
        count: length(placements),
        placements: Enum.map(placements, &format_placement/1)
      })
    else
      conn
      |> put_status(404)
      |> json(%{error: "invalid shelf name"})
    end
  end

  defp format_placement(placement) do
    book =
      case placement.book do
        %Ecto.Association.NotLoaded{} -> nil
        nil -> nil
        b -> %{id: b.id, isbn: b.isbn, title: b.title, cover_image_url: b.cover_image_url}
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
