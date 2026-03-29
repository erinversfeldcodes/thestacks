defmodule StacksWeb.GroupController do
  @moduledoc "Endpoints for reading group management."

  use CoreWeb, :controller

  alias Stacks.Social
  alias StacksWeb.ProtoJSON

  action_fallback CoreWeb.FallbackController

  def create(conn, params) do
    user = Guardian.Plug.current_resource(conn)
    # Social.create_group/2 merges %{owner_id: id} (atom key) into attrs,
    # so we use atom keys to avoid Ecto's mixed-key cast error.
    attrs =
      %{name: params["name"], type: params["type"], visibility: params["visibility"]}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Social.create_group(user.id, attrs) do
      {:ok, group} ->
        conn
        |> put_status(:created)
        |> json(%{group: ProtoJSON.group(group)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => group_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Social.get_group(group_id, user.id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "not found"})
      group -> json(conn, %{group: ProtoJSON.group(group)})
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
