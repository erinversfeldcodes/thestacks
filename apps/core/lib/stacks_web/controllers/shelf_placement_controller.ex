defmodule StacksWeb.ShelfPlacementController do
  @moduledoc "Handles placement creation, movement, and removal."

  use CoreWeb, :controller

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement}

  @valid_shelves ~w(antilibrary library wishlist reading_pile looking_for_home)

  @doc "POST /api/shelves/:shelf_name/placements — place a book on a shelf."
  def create(conn, %{"shelf_name" => shelf_name, "book_id" => book_id}) do
    if shelf_name in @valid_shelves do
      user = Guardian.Plug.current_resource(conn)

      case Shelving.place_book(user.id, book_id, shelf_name) do
        {:ok, placement} ->
          conn
          |> put_status(201)
          |> json(%{placement: format_placement(placement)})

        {:error, changeset} ->
          conn
          |> put_status(422)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      conn
      |> put_status(422)
      |> json(%{error: "invalid shelf name"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "book_id is required"})
  end

  @doc "PUT /api/placements/:id/move — move a placement to a different shelf."
  def move(conn, %{"id" => placement_id, "shelf" => to_shelf}) do
    user = Guardian.Plug.current_resource(conn)

    case Shelving.move_book(placement_id, user.id, to_shelf) do
      {:ok, %{placement: placement}} ->
        json(conn, %{placement: format_placement(placement)})

      {:error, :unauthorized} ->
        conn
        |> put_status(403)
        |> json(%{error: "forbidden"})

      {:error, _, reason, _} ->
        conn
        |> put_status(422)
        |> json(%{error: inspect(reason)})
    end
  end

  def move(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "shelf parameter is required"})
  end

  @doc "DELETE /api/placements/:id — soft-delete (remove) a placement."
  def delete(conn, %{"id" => placement_id}) do
    user = Guardian.Plug.current_resource(conn)

    placement =
      Placement
      |> Repo.get(placement_id)
      |> case do
        nil -> nil
        p -> Repo.preload(p, :bookshelf)
      end

    case placement do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "not found"})

      %Placement{bookshelf: %Bookshelf{user_id: owner_id}} when owner_id != user.id ->
        conn
        |> put_status(403)
        |> json(%{error: "forbidden"})

      _ ->
        case Shelving.remove_book(placement_id, user.id) do
          {:ok, _placement} ->
            send_resp(conn, 204, "")

          {:error, changeset} ->
            conn
            |> put_status(422)
            |> json(%{errors: format_errors(changeset)})
        end
    end
  end

  defp format_placement(placement) do
    %{
      id: placement.id,
      book_id: placement.book_id,
      bookshelf_id: placement.bookshelf_id,
      position: placement.position,
      placed_at: placement.placed_at,
      removed_at: placement.removed_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
