defmodule StacksWeb.BookshelfController do
  @moduledoc "Returns books on a named bookshelf for the current user."

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving
  alias Stacks.Visibility
  alias StacksWeb.Plugs.ViewAsPlug
  alias StacksWeb.ProtoJSON

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

  @doc "PUT /api/bookshelves/:bookshelf_name/visibility — update a bookshelf's visibility."
  def update_visibility(conn, %{"bookshelf_name" => bookshelf_name, "visibility" => visibility}) do
    if bookshelf_name in @valid_bookshelves do
      user = Guardian.Plug.current_resource(conn)

      case Shelving.set_bookshelf_visibility(user.id, bookshelf_name, visibility) do
        {:ok, bookshelf} ->
          json(conn, ProtoJSON.visibility_update(bookshelf))

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
      end
    else
      conn |> put_status(404) |> json(%{error: "invalid bookshelf name"})
    end
  end

  def update_visibility(conn, _params) do
    conn |> put_status(422) |> json(%{error: "visibility is required"})
  end

  defp render_bookshelf(conn, user, bookshelf_name, viewer) do
    case Shelving.get_bookshelf(user.id, bookshelf_name) do
      nil ->
        json(conn, %{bookshelf: bookshelf_name, count: 0, shelves: []})

      bookshelf ->
        render_visible_bookshelf(conn, user, bookshelf_name, bookshelf, viewer)
    end
  end

  defp render_visible_bookshelf(conn, user, bookshelf_name, bookshelf, viewer) do
    if Visibility.resolve_visibility(bookshelf, viewer) == :hidden do
      conn |> put_status(404) |> json(%{error: "not_found"})
    else
      shelves = Shelving.get_bookshelf_shelves(user.id, bookshelf_name)
      shelf_json = Enum.map(shelves, &ProtoJSON.shelf_with_placements(&1, viewer))
      placement_count = shelf_json |> Enum.flat_map(& &1.placements) |> length()

      json(conn, %{
        bookshelf: bookshelf_name,
        count: placement_count,
        shelves: shelf_json
      })
    end
  end
end
