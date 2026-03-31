defmodule StacksWeb.VisibilityGrantController do
  @moduledoc "Endpoints for managing visibility grants on group-visibility bookshelves."

  use CoreWeb, :controller

  alias Stacks.Social
  alias StacksWeb.ProtoJSON

  action_fallback CoreWeb.FallbackController

  def create(conn, %{"bookshelf_id" => bookshelf_id, "user_id" => grantee_user_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.grant_visibility(bookshelf_id, user.id, grantee_user_id) do
      {:ok, grant} ->
        conn
        |> put_status(:created)
        |> json(%{grant: ProtoJSON.visibility_grant(grant)})

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :not_applicable} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "bookshelf is not group visibility"})

      {:error, :already_granted} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "grant already exists"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def index(conn, %{"bookshelf_id" => bookshelf_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.list_visibility_grants(bookshelf_id, user.id) do
      {:ok, grants} ->
        json(conn, %{grants: Enum.map(grants, &ProtoJSON.visibility_grant/1)})

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def delete(conn, %{"bookshelf_id" => bookshelf_id, "user_id" => grantee_user_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.revoke_visibility(bookshelf_id, user.id, grantee_user_id) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end
end
