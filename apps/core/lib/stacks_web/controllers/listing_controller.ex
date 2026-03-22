defmodule StacksWeb.ListingController do
  @moduledoc "Handles marketplace listing CRUD and state transitions."

  use CoreWeb, :controller

  action_fallback CoreWeb.FallbackController

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
      nil -> {:error, :not_found}
      listing -> json(conn, %{listing: listing})
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

    with {:ok, listing} <- Marketplace.create_listing(user.id, params) do
      conn
      |> put_status(201)
      |> json(%{listing: listing})
    end
  end

  @doc "PUT /api/listings/:id/activate — activate a draft listing."
  def activate(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with %Listing{} = listing <- Marketplace.get_listing(id) || {:error, :not_found},
         {:ok, listing} <- Marketplace.activate_listing(listing, user.id) do
      json(conn, %{listing: listing})
    end
  end

  @doc "PUT /api/listings/:id/sold — mark an active listing as sold."
  def sold(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with %Listing{} = listing <- Marketplace.get_listing(id) || {:error, :not_found},
         {:ok, listing} <- Marketplace.sold_listing(listing, user.id) do
      json(conn, %{listing: listing})
    end
  end

  @doc "PUT /api/listings/:id/deactivate — deactivate (remove) an active listing."
  def deactivate(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with %Listing{} = listing <- Marketplace.get_listing(id) || {:error, :not_found},
         {:ok, listing} <- Marketplace.deactivate_listing(listing, user.id) do
      json(conn, %{listing: listing})
    end
  end
end
