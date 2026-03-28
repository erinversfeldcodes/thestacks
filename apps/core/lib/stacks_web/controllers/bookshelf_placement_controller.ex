defmodule StacksWeb.BookshelfPlacementController do
  @moduledoc "Handles placement creation, movement, and removal."

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Core.Repo
  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving
  alias Stacks.Shelving.{Bookshelf, Placement}
  alias StacksWeb.ProtoJSON

  @valid_bookshelves ~w(antilibrary library wishlist reading_pile looking_for_home)

  @doc "GET /api/placements/mine — lightweight summary of user's active placements."
  def mine(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    placements = Shelving.get_user_placements_summary(user.id)
    json(conn, %{placements: placements})
  end

  @doc "POST /api/bookshelves/:bookshelf_name/placements — place a book on a bookshelf."
  def create(conn, %{"bookshelf_name" => bookshelf_name, "book_id" => book_id}) do
    if bookshelf_name in @valid_bookshelves do
      user = Guardian.Plug.current_resource(conn)

      case Shelving.place_book(user.id, book_id, bookshelf_name) do
        {:ok, placement} ->
          conn
          |> put_status(201)
          |> json(%{placement: ProtoJSON.placement_ref(placement)})

        {:error, changeset} ->
          conn
          |> put_status(422)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      conn
      |> put_status(422)
      |> json(%{error: "invalid bookshelf name"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "book_id is required"})
  end

  @doc "PUT /api/placements/:id/move — move a placement to a different bookshelf."
  def move(conn, %{"id" => placement_id, "bookshelf" => to_bookshelf}) do
    user = Guardian.Plug.current_resource(conn)

    case Shelving.move_book(placement_id, user.id, to_bookshelf) do
      {:ok, %{placement: placement}} ->
        json(conn, %{placement: ProtoJSON.placement_ref(placement)})

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
    |> json(%{error: "bookshelf parameter is required"})
  end

  @doc "PUT /api/placements/:id/formats — update the formats list for a placement."
  def update_formats(conn, %{"id" => placement_id, "formats" => formats})
      when is_list(formats) do
    user = Guardian.Plug.current_resource(conn)

    case Shelving.update_placement_formats(placement_id, user.id, formats) do
      {:ok, placement} ->
        json(conn, %{placement: ProtoJSON.placement_formats(placement)})

      {:error, :unauthorized} ->
        conn
        |> put_status(403)
        |> json(%{error: "forbidden"})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_formats(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "formats parameter is required and must be an array"})
  end

  @doc "PUT /api/placements/:id/visibility — update the visibility of a placement (ceiling rule enforced)."
  def update_visibility(conn, %{"id" => placement_id, "visibility" => visibility}) do
    user = Guardian.Plug.current_resource(conn)

    case Shelving.update_placement_visibility(placement_id, user.id, visibility) do
      {:ok, placement} ->
        json(conn, ProtoJSON.visibility_update(placement))

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, reason} when is_binary(reason) ->
        conn |> put_status(422) |> json(%{error: reason})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_visibility(conn, _params) do
    conn |> put_status(422) |> json(%{error: "visibility is required"})
  end

  @doc "PUT /api/placements/:id/progress — update reading status and/or current page."
  def update_progress(conn, %{"id" => placement_id, "reading_status" => _} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.take(params, ["reading_status", "current_page"])

    case Shelving.update_reading_progress(placement_id, user.id, attrs) do
      {:ok, placement} ->
        json(conn, %{placement: ProtoJSON.reading_progress(placement)})

      {:error, :unauthorized} ->
        conn
        |> put_status(403)
        |> json(%{error: "forbidden"})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not found"})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_progress(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "reading_status is required"})
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
end
