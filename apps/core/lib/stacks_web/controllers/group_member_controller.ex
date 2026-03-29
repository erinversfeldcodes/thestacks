defmodule StacksWeb.GroupMemberController do
  @moduledoc "Endpoints for group membership and invitations."

  use CoreWeb, :controller

  alias Stacks.Social
  alias StacksWeb.ProtoJSON

  action_fallback CoreWeb.FallbackController

  def invite(conn, %{"group_id" => group_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    identifier = Map.get(params, "identifier", "")

    case Social.invite_member(group_id, user.id, identifier) do
      {:ok, invitation} ->
        conn
        |> put_status(:created)
        |> json(%{invitation: ProtoJSON.group_invitation(invitation)})

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :user_not_found} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "user not found"})

      {:error, :already_member} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "already a member"})

      {:error, :already_invited} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "already invited"})
    end
  end

  def accept(conn, %{"group_id" => _group_id, "id" => invitation_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.accept_invitation(invitation_id, user.id) do
      {:ok, _invitation} ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  def decline(conn, %{"group_id" => _group_id, "id" => invitation_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.decline_invitation(invitation_id, user.id) do
      {:ok, _invitation} ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  def remove(conn, %{"group_id" => group_id, "user_id" => member_user_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.remove_member(group_id, user.id, member_user_id) do
      {:ok, :removed} ->
        send_resp(conn, :no_content, "")

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  def leave(conn, %{"group_id" => group_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.leave_group(group_id, user.id) do
      {:ok, :left} ->
        send_resp(conn, :no_content, "")

      {:error, :is_owner} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "cannot leave as owner"})

      {:error, :not_member} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end
end
