defmodule StacksWeb.CommentController do
  @moduledoc "Endpoints for blog post comments."

  use CoreWeb, :controller

  alias Stacks.Blog
  alias StacksWeb.ProtoJSON

  action_fallback CoreWeb.FallbackController

  def index(conn, %{"post_id" => post_id}) do
    user = Guardian.Plug.current_resource(conn)
    comments = Blog.list_comments(post_id, user.id)
    json(conn, %{comments: Enum.map(comments, &ProtoJSON.comment/1)})
  end

  def create(conn, %{"post_id" => post_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.take(params, ["body", "parent_id"])

    case Blog.create_comment(post_id, user.id, attrs) do
      {:ok, comment} ->
        conn
        |> put_status(:created)
        |> json(%{comment: ProtoJSON.comment(comment)})

      {:error, :post_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "post not found"})

      {:error, :parent_not_found} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "parent comment not found"})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => comment_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Blog.delete_comment(comment_id, user.id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not found"})
      {:error, :unauthorized} -> conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
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
