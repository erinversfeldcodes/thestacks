defmodule StacksWeb.ProfileController do
  @moduledoc """
    Public profile read surfaces for `/u/:handle` — the reader-facing half of
    the visibility model. Runs under the `:optional_auth` pipeline, so the viewer is
    either an authenticated platform user or `:unauthenticated`.

    Everything is visibility-gated by `Stacks.Visibility`: a ghost profile
    (`profile_visibility: "owner"`) or a blocked pair renders **404 (not 403)** so a
    hidden profile is indistinguishable from a non-existent one. Shelves and
    placements are filtered by `resolve_visibility/2` for the viewer — the same gate
    the owner's own bookshelf view uses, pointed at the target user.
  """
  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Shelving
  alias Stacks.Visibility
  alias StacksWeb.ProtoJSON

  @valid_bookshelves ~w(antilibrary library wishlist reading_pile looking_for_home)

  @default_public_shelf_cap 500

  @doc "GET /api/u/:handle — a user's public profile + their viewer-visible shelves."
  def show(conn, %{"handle" => handle}) do
    with_visible_profile(conn, handle, fn target, viewer ->
      shelves = Visibility.viewable_shelves(target.id, viewer)
      json(conn, ProtoJSON.public_profile(target, shelves))
    end)
  end

  @doc "GET /api/u/:handle/bookshelves/:bookshelf_name — a user's shelf, visibility-filtered."
  def shelf(conn, %{"handle" => handle, "bookshelf_name" => bookshelf_name}) do
    if bookshelf_name in @valid_bookshelves do
      with_visible_profile(conn, handle, fn target, viewer ->
        render_shelf(conn, target, bookshelf_name, viewer)
      end)
    else
      not_found(conn)
    end
  end

  defp with_visible_profile(conn, handle, fun) do
    viewer = build_viewer(conn)

    case Accounts.get_user_by_handle(handle) do
      nil ->
        emit_profile_view(:not_found)
        not_found(conn)

      target ->
        if Visibility.profile_visible?(target, viewer) do
          emit_profile_view(:ok)
          fun.(target, viewer)
        else
          emit_profile_view(:not_found)
          not_found(conn)
        end
    end
  end

  defp emit_profile_view(outcome) when outcome in [:ok, :not_found] do
    :telemetry.execute([:stacks, :profile, :view], %{count: 1}, %{outcome: outcome})
  end

  defp render_shelf(conn, target, bookshelf_name, viewer) do
    bookshelf = Shelving.get_bookshelf(target.id, bookshelf_name)

    if is_nil(bookshelf) or Visibility.resolve_visibility(bookshelf, viewer) == :hidden do
      json(conn, %{bookshelf: bookshelf_name, count: 0, shelves: []})
    else
      shelves = Shelving.get_bookshelf_shelves(target.id, bookshelf_name)

      visible =
        shelves |> Enum.flat_map(& &1.placements) |> Visibility.filter_visible_placements(viewer)

      cap = public_shelf_cap()
      visible_ids = visible |> Enum.take(cap) |> MapSet.new(& &1.id)

      if length(visible) > cap do
        :telemetry.execute([:stacks, :shelf, :browse_capped], %{count: 1}, %{})
      end

      shelf_json =
        Enum.map(shelves, fn shelf ->
          placements =
            shelf.placements
            |> Enum.filter(&MapSet.member?(visible_ids, &1.id))
            |> Enum.map(&ProtoJSON.placement_detail/1)

          %{id: shelf.id, position: shelf.position, placements: placements}
        end)

      json(conn, %{
        bookshelf: bookshelf_name,
        count: MapSet.size(visible_ids),
        shelves: shelf_json
      })
    end
  end

  defp build_viewer(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> :unauthenticated
      %{id: id} -> {:platform_user, id}
    end
  end

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp public_shelf_cap,
    do: Application.get_env(:core, :public_shelf_cap, @default_public_shelf_cap)
end
