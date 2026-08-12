defmodule StacksWeb.ShelfController do
  @moduledoc "Manages physical shelves within a bookshelf."

  use CoreWeb, :controller

  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving

  @valid_bookshelves ~w(antilibrary library wishlist reading_pile looking_for_home)

  @doc "GET /api/bookshelves/:bookshelf_name/shelves"
  def index(conn, %{"bookshelf_name" => bookshelf_name}) do
    if bookshelf_name in @valid_bookshelves do
      user = Guardian.Plug.current_resource(conn)
      bookshelf = Shelving.get_bookshelf(user.id, bookshelf_name)

      case bookshelf do
        nil ->
          json(conn, %{shelves: []})

        bs ->
          shelves =
            bs.id
            |> Shelving.list_shelves()
            |> Enum.map(&shelf_json/1)

          json(conn, %{shelves: shelves})
      end
    else
      conn |> put_status(404) |> json(%{error: "invalid bookshelf name"})
    end
  end

  @doc "POST /api/bookshelves/:bookshelf_name/shelves"
  def create(conn, %{"bookshelf_name" => bookshelf_name}) do
    if bookshelf_name in @valid_bookshelves do
      user = Guardian.Plug.current_resource(conn)
      bookshelf = Shelving.get_bookshelf(user.id, bookshelf_name)

      case bookshelf do
        nil ->
          conn |> put_status(404) |> json(%{error: "bookshelf not found"})

        bs ->
          do_create_shelf(conn, bs.id, user.id)
      end
    else
      conn |> put_status(404) |> json(%{error: "invalid bookshelf name"})
    end
  end

  @doc "DELETE /api/shelves/:id"
  def delete(conn, %{"id" => shelf_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Shelving.delete_shelf(shelf_id, user.id) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, :not_empty} ->
        conn |> put_status(422) |> json(%{error: "shelf is not empty"})
    end
  end

  @doc "PUT /api/bookshelves/:bookshelf_name/shelves/reorder"
  def reorder(conn, %{"bookshelf_name" => bookshelf_name, "shelf_ids" => shelf_ids})
      when is_list(shelf_ids) do
    if bookshelf_name in @valid_bookshelves do
      user = Guardian.Plug.current_resource(conn)
      bookshelf = Shelving.get_bookshelf(user.id, bookshelf_name)

      case bookshelf do
        nil ->
          conn |> put_status(404) |> json(%{error: "bookshelf not found"})

        bs ->
          do_reorder_shelves(conn, bs.id, user.id, shelf_ids)
      end
    else
      conn |> put_status(404) |> json(%{error: "invalid bookshelf name"})
    end
  end

  def reorder(conn, _params) do
    conn |> put_status(422) |> json(%{error: "shelf_ids is required"})
  end

  defp do_create_shelf(conn, bookshelf_id, user_id) do
    case Shelving.create_shelf(bookshelf_id, user_id) do
      {:ok, shelf} -> conn |> put_status(201) |> json(%{shelf: shelf_json(shelf)})
      {:error, :unauthorized} -> conn |> put_status(403) |> json(%{error: "forbidden"})
    end
  end

  defp do_reorder_shelves(conn, bookshelf_id, user_id, shelf_ids) do
    case Shelving.reorder_shelves(bookshelf_id, user_id, shelf_ids) do
      :ok -> json(conn, %{ok: true})
      {:error, :unauthorized} -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, :invalid_ids} -> conn |> put_status(422) |> json(%{error: "invalid shelf IDs"})
    end
  end

  defp shelf_json(shelf) do
    %{
      id: shelf.id,
      bookshelf_id: shelf.bookshelf_id,
      position: shelf.position,
      created_at: shelf.created_at
    }
  end
end
