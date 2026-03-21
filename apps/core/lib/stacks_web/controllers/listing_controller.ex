defmodule StacksWeb.ListingController do
  @moduledoc "Handles marketplace listing CRUD and state transitions."

  use CoreWeb, :controller

  import StacksWeb.ChangesetHelpers, only: [format_errors: 1]

  alias Stacks.Accounts.Guardian
  alias Stacks.Marketplace
  alias Stacks.Marketplace.Listing

  @doc "GET /api/listings — list all active listings."
  def index(conn, _params) do
    listings = Marketplace.list_active_listings()
    json(conn, %{listings: listings})
  end

  @doc "GET /api/listings/:id — show a single listing."
  def show(conn, %{"id" => id}) do
    case Marketplace.get_listing(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      listing ->
        json(conn, %{listing: listing})
    end
  end

  @doc "GET /api/listings/mine — list the current user's listings."
  def mine(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    listings = Marketplace.list_user_listings(user.id)
    json(conn, %{listings: listings})
  end

  @doc "POST /api/listings — create a new draft listing."
  def create(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    case Marketplace.create_listing(user.id, params) do
      {:ok, listing} ->
        conn
        |> put_status(201)
        |> json(%{listing: listing})

      {:error, :no_placement} ->
        conn
        |> put_status(422)
        |> json(%{error: "you must own a placement of this book"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc "PUT /api/listings/:id/activate — activate a draft listing."
  def activate(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case Marketplace.get_listing(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      %Listing{} = listing ->
        case Marketplace.activate_listing(listing, user.id) do
          {:ok, listing} ->
            json(conn, %{listing: listing})

          {:error, :unauthorized} ->
            conn |> put_status(403) |> json(%{error: "forbidden"})

          {:error, :invalid_transition} ->
            conn |> put_status(422) |> json(%{error: "invalid state transition"})

          {:error, %Ecto.Changeset{} = changeset} ->
            conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
        end
    end
  end

  @doc "PUT /api/listings/:id/deactivate — deactivate (remove) an active listing."
  def deactivate(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case Marketplace.get_listing(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      %Listing{} = listing ->
        case Marketplace.deactivate_listing(listing, user.id) do
          {:ok, listing} ->
            json(conn, %{listing: listing})

          {:error, :unauthorized} ->
            conn |> put_status(403) |> json(%{error: "forbidden"})

          {:error, :invalid_transition} ->
            conn |> put_status(422) |> json(%{error: "invalid state transition"})

          {:error, %Ecto.Changeset{} = changeset} ->
            conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
        end
    end
  end
end
