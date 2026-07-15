defmodule StacksWeb.SocialController do
  @moduledoc "Handles user block/unblock and blocked-users list."

  use CoreWeb, :controller

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Social

  @doc "POST /api/users/:id/block — block a user."
  def block(conn, %{"id" => target_id}) do
    user = Guardian.Plug.current_resource(conn)

    cond do
      user.id == target_id ->
        :telemetry.execute(
          [:stacks, :social, :block_error],
          %{count: 1},
          %{reason: :cannot_block_self}
        )

        conn |> put_status(422) |> json(%{error: "cannot_block_self"})

      Accounts.get_user(target_id) == nil ->
        :telemetry.execute(
          [:stacks, :social, :block_error],
          %{count: 1},
          %{reason: :not_found}
        )

        conn |> put_status(404) |> json(%{error: "not_found"})

      true ->
        case Social.block_user(user.id, target_id) do
          {:ok, _} -> json(conn, %{blocked: true})
          {:error, _} -> conn |> put_status(422) |> json(%{error: "already_blocked"})
        end
    end
  end

  @doc "DELETE /api/users/:id/block — unblock a user."
  def unblock(conn, %{"id" => target_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.unblock_user(user.id, target_id) do
      {:ok, :unblocked} -> json(conn, %{blocked: false})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  @doc "GET /api/settings/blocked-users — paginated list of blocked users."
  def blocked_users(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    page =
      case Integer.parse(Map.get(params, "page", "1")) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    {blocked, total} = Social.list_blocked_users(user.id, page: page)

    json(conn, %{blocked_users: blocked, total: total, page: page})
  end
end
